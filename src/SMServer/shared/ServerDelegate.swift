import Foundation
import Criollo

#if os(iOS)
import UIKit
#endif

struct APIError: Error {
	let status: UInt
	let code: String
	let message: String
	let details: [String: Any]?

	init(_ status: UInt, _ code: String, _ message: String, details: [String: Any]? = nil) {
		self.status = status
		self.code = code
		self.message = message
		self.details = details
	}

	static func badRequest(_ message: String, details: [String: Any]? = nil) -> APIError {
		return APIError(400, "bad_request", message, details: details)
	}

	static func unauthorized() -> APIError {
		return APIError(401, "unauthorized", "Authentication required")
	}

	static func forbidden(_ message: String) -> APIError {
		return APIError(403, "forbidden", message)
	}

	static func notFound(_ message: String) -> APIError {
		return APIError(404, "not_found", message)
	}

	static func methodNotAllowed(_ allowed: [String]) -> APIError {
		return APIError(405, "method_not_allowed", "Method not allowed", details: ["allow": allowed])
	}

	static func sendFailed(_ message: String) -> APIError {
		return APIError(502, "send_failed", message)
	}

	static func invalidSender(_ message: String, details: [String: Any]) -> APIError {
		return APIError(400, "invalid_sender", message, details: details)
	}

	static func tweakUnreachable(_ message: String) -> APIError {
		return APIError(502, "tweak_unreachable", message)
	}
}

struct SendOutcome {
	let code: Int
	let reason: String?
	let service: String?
	let from: String?

	var isSenderProblem: Bool {
		return reason?.hasPrefix("sender_") ?? false
	}
}

struct APIAuth {
	enum Method: String {
		case apiToken = "api_token"
		case session = "session"
		case ip = "ip"
		case disabled = "disabled"
		case none = "none"
	}

	let method: Method
	let token: String?
	let expiresAt: Int?

	var authenticated: Bool {
		return method != .none
	}
}

final class SessionStore {
	private var sessions: [String: Date] = [String: Date]()
	private let lock = NSLock()

	private func ttl() -> TimeInterval {
		let configured = Settings.shared().session_ttl_seconds
		return TimeInterval(configured > 0 ? configured : 86400)
	}

	private func purgeLocked(now: Date) {
		sessions = sessions.filter({ $0.value > now })
	}

	func create() -> (token: String, expiresAt: Date) {
		let token = Const.api_session_token_prefix + Settings.generateToken(byteCount: 24)
		let expires = Date().addingTimeInterval(ttl())
		lock.lock()
		purgeLocked(now: Date())
		sessions[token] = expires
		let count = sessions.count
		lock.unlock()
		Const.log("event=auth.session.created active=\(count)")
		return (token, expires)
	}

	func touch(_ token: String) -> Date? {
		lock.lock()
		defer { lock.unlock() }
		let now = Date()
		var matched: String? = nil
		for key in sessions.keys where Settings.constantTimeEquals(key, token) {
			matched = key
		}
		guard let key = matched, let expires = sessions[key] else {
			return nil
		}
		if expires <= now {
			sessions.removeValue(forKey: key)
			return nil
		}
		let refreshed = now.addingTimeInterval(ttl())
		sessions[key] = refreshed
		return refreshed
	}

	func revoke(_ token: String) {
		lock.lock()
		sessions.removeValue(forKey: token)
		lock.unlock()
		Const.log("event=auth.session.revoked")
	}

	func removeAll() {
		lock.lock()
		sessions.removeAll()
		lock.unlock()
	}

	func count() -> Int {
		lock.lock()
		defer { lock.unlock() }
		return sessions.filter({ $0.value > Date() }).count
	}
}

struct StaticAsset {
	let data: Data
	let mime: String
	let etag: String
}

class ServerDelegate {
	let server = CRHTTPServer()
	let socket = SocketDelegate()
	let settings = Settings.shared()
	let identity = Bundle.main.path(forResource: "identity", ofType: "pfx")

	let chat_delegate = ChatDelegate.shared()
	let starscream = StarscreamDelegate.sharedDelegate
	static let sender: IWSSender = IWSSender.init()
	static let sessions = SessionStore()
	static let auth_lock = NSLock()
	var watcher: IPCTextWatcher? = nil

	var restarted_recently: Bool = false
	var did_start = false
	var started_at: Date? = nil
	var routes_registered = false
	var last_remote_error: String? = nil
	var remote_retry_attempt: Int = 0
	static let remote_retry_max_attempts: Int = 8
	static let remote_retry_base_delay: Double = 5
	static let remote_retry_max_delay: Double = 120

	var main_page: String = ""
	var gatekeeper_page: String = ""
	var custom_style: String = ""
	var static_assets: [String: StaticAsset] = [String: StaticAsset]()
	let assets_lock = NSLock()

	let requests_page = """
	<!DOCTYPE html>
	<html><head><meta charset="utf-8"><title>SMServer API</title></head>
	<body style="font-family:-apple-system,system-ui,sans-serif;padding:24px">
	<h2>SMServer API</h2>
	<p>This is the legacy <code>/requests</code> endpoint. The documented JSON API lives under <code>/api/v1</code>.</p>
	<p>See <a href="https://github.com/iandwelker/smserver/blob/master/docs/API/v1.md">docs/API/v1.md</a>.</p>
	</body></html>
	"""

	init() {
		loadFuncs()
	}

	private static var sharedDelegate: ServerDelegate = {
		let delegate = ServerDelegate()
		return delegate
	}()

	class func shared() -> ServerDelegate {
		return sharedDelegate
	}

	func loadFuncs() {
		self.loadFiles()

		#if os(macOS)
		watcher.setUpHooks()
		#endif

		socket.watcher = self.watcher
		socket.verify_auth = { ip, token in
			return ServerDelegate.authenticate(ip: ip, token: token).authenticated
		}

		let callback: CFNotificationCallback = { (nc, observer, name, object, info) in
			DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
				NotificationCenter.default.post(name: NSNotification.Name(rawValue: "ianwelker.smserver.system.config.network_change"), object: nil)
			}
		}

		CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, callback,
										"com.apple.system.config.network_change" as CFString, nil, CFNotificationSuspensionBehavior.deliverImmediately)

		NotificationCenter.default.addObserver(self, selector: #selector(reloadServer(_:)), name: NSNotification.Name("ianwelker.smserver.system.config.network_change"), object: nil)
	}

	@objc func reloadServer(_: Notification) {
		if restarted_recently || !settings.reload_on_network_change || (!self.server.isListening && !self.did_start) { return }

		Const.log("event=server.network_change action=restart")

		restarted_recently = true

		self.stopServers(from_nc_change: true)

		if settings.override_no_wifi || Const.getWiFiAddress() != nil {
			_ = self.startServers(false)
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: {
			self.restarted_recently = false
		})
	}

	func reloadVars() {
		self.loadFiles()
	}

	func loadFiles() {
		var assets = [String: StaticAsset]()
		var html_root: URL? = nil

		if let chats = Bundle.main.url(forResource: "chats", withExtension: "html", subdirectory: "html") {
			html_root = chats.deletingLastPathComponent()
		}

		#if os(macOS)
		if html_root == nil || !FileManager.default.fileExists(atPath: html_root?.path ?? "") {
			html_root = URL(fileURLWithPath: settings.html_dir)
		}
		#endif

		if let root = html_root, let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
			let root_path = root.standardizedFileURL.path
			for case let file as URL in enumerator {
				guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
				let full = file.standardizedFileURL.path
				guard full.hasPrefix(root_path) else { continue }
				let relative = String(full.dropFirst(root_path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
				guard let data = try? Data(contentsOf: file) else {
					Const.log("event=assets.load.failed file=\(relative)", warning: true)
					continue
				}
				assets[relative] = StaticAsset(data: data, mime: Const.mimeType(forExtension: file.pathExtension), etag: ServerDelegate.etag(for: data))
			}
		} else {
			Const.log("event=assets.load.failed reason=html_dir_missing", warning: true)
		}

		self.main_page = assets["chats.html"].flatMap({ String(data: $0.data, encoding: .utf8) }) ?? ""
		self.gatekeeper_page = assets["gatekeeper.html"].flatMap({ String(data: $0.data, encoding: .utf8) }) ?? ""

		if self.main_page.isEmpty || self.gatekeeper_page.isEmpty {
			Const.log("event=assets.load.incomplete main=\(self.main_page.count) gate=\(self.gatekeeper_page.count)", warning: true)
		}

		if FileManager.default.fileExists(atPath: Const.custom_css_path.path) {
			do {
				self.custom_style = try String(contentsOf: Const.custom_css_path, encoding: .utf8)
			} catch {
				self.custom_style = ""
				Const.log("event=assets.custom_css.failed", warning: true)
			}
		} else {
			self.custom_style = ""
		}

		assets_lock.lock()
		self.static_assets = assets
		assets_lock.unlock()

		Const.log("event=assets.loaded count=\(assets.count) custom_css=\(self.custom_style.count)")

		do {
			let pass = try String(contentsOfFile: Const.cert_pass_file, encoding: .utf8)
			settings.cert_pass = pass
		} catch {
			Const.log("event=cert.password.default")
		}
	}

	func startServers(_ and_socket: Bool = true) -> (Bool, String) {
		guard let new_watch = IPCTextWatcher.sharedInstance() else {
			return (false, "You may have SMServer CLI running in the background on your device. Please check and try again.")
		}

		self.watcher = new_watch

		self.watcher?.setTexts = { value in
			if let val = value {
				self.sentOrReceivedNewText(val)
			}
		}

		self.watcher?.setTyping = { vals in
			if let v = vals as? [String:Any] {
				self.setPartyTyping(v)
			}
		}

		self.watcher?.sentTapback = { tapback, guid in
			if let guid = guid {
				self.sentTapback(tapback, guid: guid)
			}
		}

		self.watcher?.textRead = { guid in
			if let guid = guid {
				self.setTextRead(guid)
			}
		}

		if server.isListening {
			self.stopServers()
			Const.log("event=server.start reason=already_running action=restart")
		}

		if settings.is_secure {
			server.isSecure = true
			server.identityPath = identity
			server.password = settings.cert_pass
		}

		registerRoutes()

		if and_socket && settings.run_remote {
			connectRemote(attempt: 0)
		}

		_ = server.startListening(nil, portNumber: UInt(settings.server_port))
		socket.startServer(port: settings.socket_port)

		self.did_start = true
		self.started_at = Date()

		#if os(iOS)
		UIDevice.current.isBatteryMonitoringEnabled = true

		NotificationCenter.default.addObserver(self, selector: #selector(self.sendNewBatteryFromNotification(notification:)), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(self.sendNewBatteryFromNotification(notification:)), name: UIDevice.batteryStateDidChangeNotification, object: nil)
		#elseif os(macOS)
		DispatchQueue.main.async {
			while true {
				sleep(10)
				self.sendNewBattery()
			}
		}
		#endif

		guard isRunning() else {
			server.stopListening()
			socket.stopServer()
			starscream.disconnect()
			self.started_at = nil
			Const.log("event=server.start.failed port=\(settings.server_port) socket_port=\(settings.socket_port)", warning: true)
			return (false, "Unable to start local server. Please try again.")
		}

		Const.log("event=server.started port=\(settings.server_port) socket_port=\(settings.socket_port) secure=\(settings.is_secure) web=\(settings.run_web_interface)")

		return (isRunning(), "Could not start server; unknown error. Please respring/ldrestart/reinstall, etc. and try again")
	}

	func stopServers(from_nc_change: Bool = false) {
		self.server.stopListening()
		self.socket.stopServer()

		Const.log("event=server.stopped network_change=\(from_nc_change)")

		if !from_nc_change {
			self.starscream.disconnect()
			self.last_remote_error = nil

			ServerDelegate.auth_lock.lock()
			settings.authenticated_addresses = [String]()
			ServerDelegate.auth_lock.unlock()
			ServerDelegate.sessions.removeAll()
			self.did_start = false
			self.started_at = nil
		}
	}

	func isRunning() -> Bool {
		return server.isListening && socket.server != nil && socket.server?.isRunning ?? false
	}

	func connectRemote(attempt: Int) {
		remote_retry_attempt = attempt

		if starscream.registerAndConnect() {
			last_remote_error = nil
			Const.log("event=remote.connect.started addr=\(settings.remote_addr) attempt=\(attempt)")
			return
		}

		let message = "Unable to connect to the remote server at \(settings.remote_addr). The local server keeps running; check the remote settings."
		last_remote_error = message
		starscream.setSocketState(new_state: .FailedConnect)
		Const.log("event=remote.connect.failed addr=\(settings.remote_addr) attempt=\(attempt) secure=\(settings.remote_secure)", warning: true)

		scheduleRemoteRetry(after: attempt)
	}

	func scheduleRemoteRetry(after attempt: Int) {
		guard attempt < ServerDelegate.remote_retry_max_attempts else {
			Const.log("event=remote.connect.giving_up addr=\(settings.remote_addr) attempts=\(attempt + 1)", warning: true)
			return
		}

		let delay = min(ServerDelegate.remote_retry_base_delay * pow(2.0, Double(attempt)), ServerDelegate.remote_retry_max_delay)
		Const.log("event=remote.connect.retry_scheduled attempt=\(attempt + 1) delay_s=\(Int(delay))")

		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
			guard self.did_start, self.settings.run_remote else {
				Const.log("event=remote.connect.retry_cancelled reason=\(self.did_start ? "remote_disabled" : "server_stopped")")
				return
			}
			switch self.starscream.socket_state {
				case .Connected, .Connecting, .Reconnecting:
					Const.log("event=remote.connect.retry_skipped state=\(self.starscream.socket_state)")
				default:
					self.connectRemote(attempt: attempt + 1)
			}
		}
	}

	func tweakPing() -> [String: Any]? {
		#if os(iOS)
		return ServerDelegate.sender.ping() as? [String: Any]
		#else
		return nil
		#endif
	}

	func watcherListening() -> Bool {
		#if os(iOS)
		return watcher?.isListening() ?? false
		#else
		return watcher != nil
		#endif
	}

	func tweakSummary() -> [String: Any] {
		let started = Date()
		let info = tweakPing()
		let elapsed = Int(Date().timeIntervalSince(started) * 1000)
		let connected: Bool = {
			if let flag = info?["connected"] as? Bool { return flag }
			if let number = info?["connected"] as? NSNumber { return number.boolValue }
			return false
		}()

		Const.log("event=tweak.ping reachable=\(info != nil) connected=\(connected) ms=\(elapsed)")

		return [
			"reachable": info != nil,
			"connected": connected,
			"version": ServerDelegate.orNull(info?["version"]),
			"pid": ServerDelegate.orNull(info?["pid"]),
			"capabilities": ServerDelegate.orNull(info?["capabilities"]),
			"watcher_listening": watcherListening(),
			"latency_ms": elapsed,
		]
	}

	func connectedClientCount() -> Int {
		return socket.server?.webSocketCount ?? 0
	}

	func uptime() -> Double {
		guard let started = started_at else { return 0 }
		return (Date().timeIntervalSince(started) * 10).rounded() / 10
	}

	@objc func sendNewBatteryFromNotification(notification: Notification) {
		self.sendNewBattery()
	}

	func sendNewBattery() {
		starscream.sendBattery()
		socket.sendNewBattery()
	}

	static func etag(for data: Data) -> String {
		var hash: UInt64 = 0xcbf29ce484222325
		for byte in data {
			hash ^= UInt64(byte)
			hash = hash &* 0x100000001b3
		}
		return "\"\(data.count)-\(String(hash, radix: 16))\""
	}

	static func authenticate(ip: String, token: String?) -> APIAuth {
		let settings = Settings.shared()

		if !settings.require_authentication {
			return APIAuth(method: .disabled, token: nil, expiresAt: nil)
		}

		if let token = token, !token.isEmpty {
			if settings.api_token_enabled && Settings.constantTimeEquals(token, settings.api_token) {
				return APIAuth(method: .apiToken, token: token, expiresAt: nil)
			}
			if let expires = sessions.touch(token) {
				return APIAuth(method: .session, token: token, expiresAt: Int(expires.timeIntervalSince1970))
			}
		}

		auth_lock.lock()
		let ip_ok = settings.authenticated_addresses.contains(ip)
		auth_lock.unlock()

		if ip_ok {
			return APIAuth(method: .ip, token: nil, expiresAt: nil)
		}

		return APIAuth(method: .none, token: nil, expiresAt: nil)
	}

	static func rememberAddress(_ ip: String) {
		guard !ip.isEmpty else { return }
		let settings = Settings.shared()
		auth_lock.lock()
		if !settings.authenticated_addresses.contains(ip) {
			settings.authenticated_addresses.append(ip)
		}
		auth_lock.unlock()
	}

	static func forgetAddress(_ ip: String) {
		let settings = Settings.shared()
		auth_lock.lock()
		settings.authenticated_addresses.removeAll(where: { $0 == ip })
		auth_lock.unlock()
	}

	static func checkIfAuthenticated(ras: String) -> Bool {
		return authenticate(ip: ras, token: nil).authenticated
	}

	static func remoteAddress(_ req: CRRequest) -> String {
		if let address = req.connection?.remoteAddress, !address.isEmpty {
			return address
		}
		return req.env["REMOTE_ADDR"] ?? ""
	}

	static func bearerToken(_ req: CRRequest) -> String? {
		if let header = req.value(forHTTPHeaderField: Const.api_auth_header) {
			let trimmed = header.trimmingCharacters(in: .whitespaces)
			if trimmed.lowercased().hasPrefix(Const.api_bearer_prefix.lowercased()) {
				let token = String(trimmed.dropFirst(Const.api_bearer_prefix.count)).trimmingCharacters(in: .whitespaces)
				if !token.isEmpty { return token }
			}
		}
		if let query_token = req.query[Const.api_token_query_key], !query_token.isEmpty {
			return query_token
		}
		return nil
	}

	static func authenticate(_ req: CRRequest) -> APIAuth {
		return authenticate(ip: remoteAddress(req), token: bearerToken(req))
	}

	static func requestPath(_ req: CRRequest) -> String {
		let path = req.url.path
		if !path.isEmpty { return path }
		return req.env["DOCUMENT_URI"] ?? "/"
	}

	static func pathComponents(_ path: String, prefix: String) -> [String] {
		var relative = path
		if relative.hasPrefix(prefix) {
			relative = String(relative.dropFirst(prefix.count))
		}
		return relative
			.split(separator: "/", omittingEmptySubsequences: true)
			.map({ String($0).removingPercentEncoding ?? String($0) })
	}

	static let url_segment_allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

	static func encodeSegment(_ value: String) -> String {
		return value.addingPercentEncoding(withAllowedCharacters: url_segment_allowed) ?? value
	}

	static func attachmentURL(_ filename: String) -> String {
		let encoded = filename.split(separator: "/").map({ encodeSegment(String($0)) }).joined(separator: "/")
		return "\(Const.api_v1_prefix)/attachments/\(encoded)"
	}

	static func photoURL(_ path: String) -> String {
		let encoded = path.split(separator: "/").map({ encodeSegment(String($0)) }).joined(separator: "/")
		return "\(Const.api_v1_prefix)/photos/\(encoded)"
	}

	static func contactPhotoURL(_ chat_id: String) -> String {
		return "\(Const.api_v1_prefix)/contacts/\(encodeSegment(chat_id))/photo"
	}

	static func decorateMessage(_ message: [String: Any], chat: String? = nil) -> [String: Any] {
		var decorated = message

		if let date = decorated["date"] as? Int {
			decorated["date_unix"] = Const.appleToUnix(Double(date))
		}

		if let read = decorated["date_read"] as? Int, read > 0 {
			decorated["date_read_unix"] = Const.appleToUnix(Double(read))
		} else {
			decorated["date_read_unix"] = NSNull()
		}

		if let attachments = decorated["attachments"] as? [[String: String]] {
			decorated["attachments"] = attachments.map({ att -> [String: Any] in
				var item: [String: Any] = att
				item["url"] = attachmentURL(att["filename"] ?? "")
				return item
			})
		}

		if let chat = chat, (decorated["chat_identifier"] as? String ?? "").isEmpty {
			decorated["chat_identifier"] = chat
		}

		if decorated["destination_caller_id"] == nil {
			decorated["destination_caller_id"] = NSNull()
		}

		return decorated
	}

	static func decorateChat(_ chat: [String: Any]) -> [String: Any] {
		var decorated = chat
		if let marker = decorated["time_marker"] as? Int {
			decorated["time_marker_unix"] = Const.appleToUnix(Double(marker))
		}
		if let id = decorated["chat_identifier"] as? String {
			decorated["avatar_url"] = contactPhotoURL(id)
		}
		if decorated["pinned"] == nil {
			decorated["pinned"] = false
		}
		if decorated["from"] == nil {
			decorated["from"] = NSNull()
		}
		return decorated
	}

	static func parseBool(_ raw: String?, default fallback: Bool) -> Bool {
		guard let value = raw?.lowercased() else { return fallback }
		if ["true", "1", "yes", "on"].contains(value) { return true }
		if ["false", "0", "no", "off"].contains(value) { return false }
		return fallback
	}

	static func parseInt(_ raw: String?) -> Int? {
		guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
		return Int(value)
	}

	static func jsonBody(_ req: CRRequest) -> [String: Any] {
		if let dict = req.body as? [String: Any] {
			return dict
		}
		if let data = req.bodyData, !data.isEmpty,
		   let parsed = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
			return parsed
		}
		return [String: Any]()
	}

	static func bodyString(_ body: [String: Any], _ key: String) -> String? {
		if let value = body[key] as? String { return value }
		if let number = body[key] as? NSNumber { return number.stringValue }
		return nil
	}

	static func bodyBool(_ body: [String: Any], _ key: String, default fallback: Bool) -> Bool {
		if let value = body[key] as? Bool { return value }
		if let number = body[key] as? NSNumber { return number.boolValue }
		return parseBool(body[key] as? String, default: fallback)
	}

	func corsHeaders(_ req: CRRequest) -> [String: String] {
		guard settings.cors_enabled else { return [String: String]() }

		let origins = settings.corsOriginList()
		let origin = req.value(forHTTPHeaderField: "Origin")
		var headers = [String: String]()

		if origins.contains("*") {
			headers["Access-Control-Allow-Origin"] = "*"
		} else if let origin = origin, origins.contains(where: { $0.caseInsensitiveCompare(origin) == .orderedSame }) {
			headers["Access-Control-Allow-Origin"] = origin
			headers["Vary"] = "Origin"
		} else {
			return headers
		}

		headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
		headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, X-Requested-With, Range"
		headers["Access-Control-Expose-Headers"] = "Content-Disposition, Content-Range, Content-Length, Accept-Ranges"
		headers["Access-Control-Max-Age"] = "600"
		return headers
	}

	func applyHeaders(_ res: CRResponse, _ headers: [String: String]) {
		for (key, value) in headers {
			res.setValue(value, forHTTPHeaderField: key)
		}
	}

	static func orNull(_ value: Any?) -> Any {
		if let value = value { return value }
		return NSNull()
	}

	func sendJSON(_ res: CRResponse, status: UInt = 200, _ object: [String: Any], extra: [String: String] = [String: String]()) {
		guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
			Const.log("event=api.response.encode_failed status=\(status)", warning: true)
			res.setStatusCode(500, description: "Internal Server Error")
			res.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
			res.send(Data("{\"error\":{\"code\":\"internal_error\",\"message\":\"Could not encode response\"}}".utf8))
			return
		}

		if status != 200 {
			res.setStatusCode(status, description: HTTPURLResponse.localizedString(forStatusCode: Int(status)))
		}
		res.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
		res.setValue("no-store", forHTTPHeaderField: "Cache-Control")
		applyHeaders(res, extra)
		res.send(data)
	}

	func sendError(_ res: CRResponse, _ error: APIError, extra: [String: String] = [String: String]()) {
		var body: [String: Any] = ["code": error.code, "message": error.message]
		if let details = error.details {
			body["details"] = details
		}
		var headers = extra
		if error.status == 401 {
			headers["WWW-Authenticate"] = "Bearer realm=\"SMServer\""
		}
		if error.status == 405, let allow = error.details?["allow"] as? [String] {
			headers["Allow"] = allow.joined(separator: ", ")
		}
		sendJSON(res, status: error.status, ["error": body], extra: headers)
	}

	func sendBinary(_ res: CRResponse, data: Data, mime: String, extra: [String: String] = [String: String]()) {
		res.setValue(mime, forHTTPHeaderField: "Content-Type")
		applyHeaders(res, extra)
		res.send(data)
	}

	func renderPage(_ template: String, config: [String: Any]) -> String {
		guard JSONSerialization.isValidJSONObject(config), let data = try? JSONSerialization.data(withJSONObject: config, options: []) else {
			return template.replacingOccurrences(of: Const.api_html_config_placeholder, with: "{}")
		}
		let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
		return template.replacingOccurrences(of: Const.api_html_config_placeholder, with: json)
	}

	func pageConfig(token: String?) -> [String: Any] {
		var subdir: Any = NSNull()
		if let configured = settings.socket_subdirectory {
			let trimmed = configured.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
			if !trimmed.isEmpty {
				subdir = trimmed
			}
		}

		return [
			"api_base": Const.api_v1_prefix,
			"static_base": Const.api_static_prefix,
			"token": token ?? "",
			"socket_port": settings.socket_port,
			"socket_subdirectory": subdir,
			"secure": settings.is_secure,
			"theme": settings.themeName(),
			"subjects_enabled": settings.subjects_enabled,
			"send_typing": settings.send_typing,
			"mark_when_read": settings.mark_when_read,
			"debug": settings.debug,
			"version": Const.appVersion(),
			"defaults": [
				"chats": Int(settings.default_num_chats),
				"messages": Int(settings.default_num_messages),
				"photos": Int(settings.default_num_photos),
			],
			"custom_css": !custom_style.isEmpty,
		]
	}

	func asset(named name: String) -> StaticAsset? {
		assets_lock.lock()
		defer { assets_lock.unlock() }
		return static_assets[name]
	}

	func registerRoutes() {
		guard !routes_registered else { return }
		routes_registered = true

		server.add(Const.api_v1_prefix, block: { (req, res, _) in
			self.handleAPIv1(req, res)
		}, recursive: true, method: .all)

		server.add(Const.api_static_prefix, block: { (req, res, _) in
			self.handleStatic(req, res)
		}, recursive: true, method: .all)

		server.add("/requests") { (req, res, _) in
			let address = ServerDelegate.remoteAddress(req)
			let query = req.query
			let token = ServerDelegate.bearerToken(req)

			Const.log("event=legacy.request path=/requests ip=\(address) keys=\(query.keys.sorted().joined(separator: ","))")

			if query.count == 0 {
				if !ServerDelegate.authenticate(ip: address, token: token).authenticated {
					res.setStatusCode(403, description: "Please authenticate")
					res.send("")
				} else {
					res.setValue("text/html", forHTTPHeaderField: "Content-type")
					res.send(self.requests_page)
				}
			} else {
				let response = ServerDelegate.parseAndReturn(params: query, address: address, token: token)

				if response.0 != 200 {
					res.setStatusCode(UInt(response.0), description: response.1 as? String ?? "")
				}

				res.send(response.1)
			}
		}

		server.add("/data") { (req, res, _) in
			let ip = ServerDelegate.remoteAddress(req)
			Const.log("event=legacy.request path=/data ip=\(ip)")

			if !ServerDelegate.authenticate(req).authenticated {
				res.setStatusCode(403, description: "Please authenticate")
				res.send("")
				return
			}

			ServerDelegate.parseDataRequest(req, res: res)
		}

		server.add("/send") { (req, res, _) in
			let ip = ServerDelegate.remoteAddress(req)
			Const.log("event=legacy.request path=/send method=\(ServerDelegate.methodName(req.method)) ip=\(ip)")

			if !ServerDelegate.authenticate(req).authenticated {
				res.setStatusCode(403, description: "Please authenticate")
				res.send("")
				return
			}

			if req.method == .post {
				let params = req.body as? Dictionary<String, Any> ?? [String:Any]()
				let files = self.collectUploadedFiles(req)
				let outcome = ServerDelegate.sendText(params: params, new_files: files)

				if outcome.code != 200 {
					let fail_msg = outcome.code == 400 && outcome.reason == nil ? "Please include either `body`, `subject`, `photos`, or `attachments` in your POST request" : ServerDelegate.sendFailureMessage(outcome.reason)
					res.setStatusCode(UInt(outcome.code), description: fail_msg)
				}
			} else if req.method == .get {
				let send_response = ServerDelegate.sendGetRequest(params: req.query)

				if send_response.0 != 200 {
					res.setStatusCode(UInt(send_response.0), description: send_response.1)
				}
			}

			res.send("")
		}

		server.add("/") { (req, res, _) in
			let ip = ServerDelegate.remoteAddress(req)
			res.setValue("text/html; charset=utf-8", forHTTPHeaderField: "Content-Type")
			res.setValue("no-store", forHTTPHeaderField: "Cache-Control")

			guard self.settings.run_web_interface else {
				Const.log("event=web.main.disabled ip=\(ip)")
				res.setStatusCode(404, description: "Web interface disabled")
				res.send("")
				return
			}

			if ServerDelegate.authenticate(req).authenticated {
				let session = ServerDelegate.sessions.create()
				Const.log("event=web.main ip=\(ip)")
				res.send(self.renderPage(self.main_page, config: self.pageConfig(token: session.token)))
			} else {
				Const.log("event=web.gatekeeper ip=\(ip)")
				res.send(self.renderPage(self.gatekeeper_page, config: self.pageConfig(token: nil)))
			}
		}

		server.add("/style") { (req, res, _) in
			guard ServerDelegate.authenticate(req).authenticated else {
				res.setStatusCode(403, description: "Please authenticate")
				res.send("")
				return
			}

			let name = req.query.keys.sorted().first ?? ""
			res.setValue("text/css", forHTTPHeaderField: "Content-Type")

			switch name {
				case "main": res.send(self.assetString("style.css") ?? self.assetString("app.css") ?? "")
				case "custom": res.send(self.custom_style)
				case "light": res.send(self.settings.light_theme ? (self.assetString("light_theme.css") ?? "") : "")
				case "nord": res.send(self.settings.nord_theme ? (self.assetString("nord_theme.css") ?? "") : "")
				case "fa_solid": res.send(self.assetString("fontawesome/fa_solid.css") ?? "")
				case "font_awesome": res.send(self.assetString("fontawesome/font_awesome.css") ?? "")
				default: res.send("")
			}
		}

		server.add("/js") { (req, res, _) in
			guard ServerDelegate.authenticate(req).authenticated else {
				res.setStatusCode(403, description: "Please authenticate")
				res.send("")
				return
			}

			let name = req.query.keys.sorted().first ?? ""
			res.setValue("application/javascript; charset=utf-8", forHTTPHeaderField: "Content-Type")
			res.send(self.assetString("\(name).js") ?? "")
		}

		server.add("/webfonts") { (req, res, _) in
			guard ServerDelegate.authenticate(req).authenticated else {
				res.setStatusCode(403, description: "Please authenticate")
				res.send("")
				return
			}

			let font = req.query.keys.sorted().first ?? ""
			if let asset = self.asset(named: "webfonts/\(font)") {
				res.setValue(asset.mime, forHTTPHeaderField: "Content-Type")
				res.send(asset.data)
				return
			}
			res.setStatusCode(404, description: "Not found")
			res.send("")
		}

		server.add("/favicon.ico") { (req, res, next) in
			let data = SMImage(named: "favicon").parseableData(png: true) ?? Data()
			res.setValue("image/png", forHTTPHeaderField: "Content-Type")
			res.setValue("public, max-age=86400", forHTTPHeaderField: "Cache-Control")
			res.send(data)
		}
	}

	func assetString(_ name: String) -> String? {
		guard let asset = asset(named: name) else { return nil }
		return String(data: asset.data, encoding: .utf8)
	}

	func handleStatic(_ req: CRRequest, _ res: CRResponse) {
		let ip = ServerDelegate.remoteAddress(req)
		let components = ServerDelegate.pathComponents(ServerDelegate.requestPath(req), prefix: Const.api_static_prefix)
		let name = components.joined(separator: "/")

		guard self.settings.run_web_interface else {
			res.setStatusCode(404, description: "Web interface disabled")
			res.send("")
			return
		}

		guard ServerDelegate.authenticate(req).authenticated else {
			Const.log("event=static.unauthorized ip=\(ip) asset=\(name)")
			res.setStatusCode(403, description: "Please authenticate")
			res.send("")
			return
		}

		guard req.method == .get || req.method == .head else {
			res.setStatusCode(405, description: "Method Not Allowed")
			res.setValue("GET", forHTTPHeaderField: "Allow")
			res.send("")
			return
		}

		if name == "custom.css" {
			res.setValue("text/css; charset=utf-8", forHTTPHeaderField: "Content-Type")
			res.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
			res.send(self.custom_style)
			return
		}

		guard !components.contains(".."), let asset = asset(named: name) else {
			Const.log("event=static.not_found asset=\(name)")
			res.setStatusCode(404, description: "Not found")
			res.send("")
			return
		}

		res.setValue(asset.mime, forHTTPHeaderField: "Content-Type")
		res.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
		res.setValue(asset.etag, forHTTPHeaderField: "ETag")

		if let match = req.value(forHTTPHeaderField: "If-None-Match"), match == asset.etag {
			res.setStatusCode(304, description: "Not Modified")
			res.send(Data())
			return
		}

		res.send(asset.data)
	}

	func collectUploadedFiles(_ req: CRRequest) -> [String] {
		var uploaded = [CRUploadedFile]()

		if let files = req.value(forKey: "files") as? NSDictionary {
			for key in files.allKeys {
				let value = files.object(forKey: key)
				if let single = value as? CRUploadedFile {
					uploaded.append(single)
				} else if let many = value as? NSArray {
					for item in many {
						if let file = item as? CRUploadedFile {
							uploaded.append(file)
						}
					}
				}
			}
		}

		let fm = FileManager.default
		var paths = [String]()

		for file in uploaded {
			let temp = file.temporaryFileURL
			let safe_name = file.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "_")
			let destination = temp.deletingLastPathComponent().appendingPathComponent(safe_name.isEmpty ? temp.lastPathComponent : safe_name)
			var moved = true

			if fm.fileExists(atPath: destination.path) {
				do {
					try fm.removeItem(at: destination)
				} catch {
					Const.log("event=upload.replace.failed path=\(destination.path)", warning: true)
					moved = false
				}
			}

			if moved {
				do {
					try fm.moveItem(at: temp, to: destination)
				} catch {
					Const.log("event=upload.move.failed path=\(destination.path)", warning: true)
					moved = false
				}
			}

			paths.append(moved ? destination.path : temp.path)
		}

		Const.log("event=upload.collected count=\(paths.count)")
		return paths
	}

	func handleAPIv1(_ req: CRRequest, _ res: CRResponse) {
		let started = Date()
		let ip = ServerDelegate.remoteAddress(req)
		let path = ServerDelegate.requestPath(req)
		let components = ServerDelegate.pathComponents(path, prefix: Const.api_v1_prefix)
		let method = req.method
		let cors = corsHeaders(req)

		Const.log("event=api.request method=\(ServerDelegate.methodName(method)) path=\(path) ip=\(ip)")

		if method == .options {
			applyHeaders(res, cors)
			res.setStatusCode(204, description: "No Content")
			res.setValue("GET, POST, PUT, DELETE, OPTIONS", forHTTPHeaderField: "Allow")
			res.send(Data())
			return
		}

		do {
			try routeAPIv1(components, method: method, req: req, res: res, ip: ip, cors: cors)
		} catch let error as APIError {
			Const.log("event=api.error status=\(error.status) code=\(error.code) path=\(path) ip=\(ip)")
			sendError(res, error, extra: cors)
		} catch {
			Const.log("event=api.error status=500 path=\(path) error=\(error)", warning: true)
			sendError(res, APIError(500, "internal_error", "Unexpected error: \(error)"), extra: cors)
		}

		let elapsed = Int(Date().timeIntervalSince(started) * 1000)
		Const.log("event=api.response status=\(res.statusCode) path=\(path) ms=\(elapsed)")
	}

	func requireAuth(_ req: CRRequest, ip: String) throws -> APIAuth {
		let auth = ServerDelegate.authenticate(req)
		guard auth.authenticated else {
			Const.log("event=api.unauthorized ip=\(ip)")
			throw APIError.unauthorized()
		}
		return auth
	}

	func requireMethod(_ method: CRHTTPMethod, oneOf allowed: [CRHTTPMethod]) throws {
		guard allowed.contains(method) else {
			throw APIError.methodNotAllowed(allowed.map({ ServerDelegate.methodName($0) }))
		}
	}

	static func methodName(_ method: CRHTTPMethod) -> String {
		switch method {
			case .get: return "GET"
			case .post: return "POST"
			case .put: return "PUT"
			case .delete: return "DELETE"
			case .patch: return "PATCH"
			case .options: return "OPTIONS"
			case .head: return "HEAD"
			default: return "ALL"
		}
	}

	func routeAPIv1(_ parts: [String], method: CRHTTPMethod, req: CRRequest, res: CRResponse, ip: String, cors: [String: String]) throws {
		guard let head = parts.first else {
			throw APIError.notFound("No such endpoint")
		}

		switch head {
			case "health":
				try requireMethod(method, oneOf: [.get])
				sendJSON(res, healthInfo(), extra: cors)

			case "server":
				try requireMethod(method, oneOf: [.get])
				_ = try requireAuth(req, ip: ip)
				if parts.count == 2 && parts[1] == "tweak" {
					sendJSON(res, tweakInfo(), extra: cors)
				} else if parts.count == 1 {
					sendJSON(res, serverInfo(req), extra: cors)
				} else {
					throw APIError.notFound("No such endpoint")
				}

			case "auth":
				try routeAuth(Array(parts.dropFirst()), method: method, req: req, res: res, ip: ip, cors: cors)

			case "chats":
				try routeChats(Array(parts.dropFirst()), method: method, req: req, res: res, ip: ip, cors: cors)

			case "messages":
				try routeMessages(Array(parts.dropFirst()), method: method, req: req, res: res, ip: ip, cors: cors)

			case "search":
				try requireMethod(method, oneOf: [.get])
				_ = try requireAuth(req, ip: ip)
				let results = try searchMessages(req)
				sendJSON(res, results, extra: cors)

			case "contacts":
				try routeContacts(Array(parts.dropFirst()), method: method, req: req, res: res, ip: ip, cors: cors)

			case "senders":
				try requireMethod(method, oneOf: [.get])
				_ = try requireAuth(req, ip: ip)
				guard parts.count == 1 else {
					throw APIError.notFound("No such endpoint")
				}
				let items = try listSenders()
				sendJSON(res, ["items": items, "count": items.count], extra: cors)

			case "imessage-status":
				try requireMethod(method, oneOf: [.get, .post])
				_ = try requireAuth(req, ip: ip)
				guard parts.count == 1 else {
					throw APIError.notFound("No such endpoint")
				}
				let result = try imessageStatus(ServerDelegate.statusAddresses(req))
				sendJSON(res, result, extra: cors)

			case "attachments":
				try requireMethod(method, oneOf: [.get])
				_ = try requireAuth(req, ip: ip)
				let path = parts.count > 1 ? Array(parts.dropFirst()).joined(separator: "/") : (req.query["path"] ?? "")
				try serveAttachment(path, req: req, res: res, cors: cors)

			case "photos":
				try requireMethod(method, oneOf: [.get])
				_ = try requireAuth(req, ip: ip)
				if parts.count > 1 {
					try servePhoto(Array(parts.dropFirst()).joined(separator: "/"), res: res, cors: cors)
				} else {
					let page = try listPhotos(req)
					sendJSON(res, page, extra: cors)
				}

			default:
				throw APIError.notFound("No such endpoint")
		}
	}

	func healthInfo() -> [String: Any] {
		return [
			"ok": true,
			"name": Const.api_product_name,
			"version": Const.appVersion(),
			"api_version": Const.api_v1_version,
			"server_time": Const.unixNow(),
			"uptime": uptime(),
		]
	}

	func serverInfo(_ req: CRRequest) -> [String: Any] {
		var device: [String: Any] = ["name": "unknown", "model": "unknown", "system": "unknown", "system_version": "unknown"]
		#if os(iOS)
		device = [
			"name": UIDevice.current.name,
			"model": UIDevice.current.model,
			"system": UIDevice.current.systemName,
			"system_version": UIDevice.current.systemVersion,
		]
		#elseif os(macOS)
		device = [
			"name": Host.current().localizedName ?? "Mac",
			"model": "Mac",
			"system": "macOS",
			"system_version": ProcessInfo.processInfo.operatingSystemVersionString,
		]
		#endif

		let state = Const.getBatteryState()
		var subdir: Any = NSNull()
		if let configured = settings.socket_subdirectory {
			let trimmed = configured.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
			if !trimmed.isEmpty { subdir = trimmed }
		}

		let host = req.value(forHTTPHeaderField: "Host")?.split(separator: ":").first.map({ String($0) }) ?? (Const.getWiFiAddress() ?? "localhost")
		let scheme = settings.is_secure ? "wss" : "ws"
		let socket_url: String = {
			if let sub = subdir as? String {
				return "\(scheme)://\(host):\(settings.server_port)/\(sub)"
			}
			return "\(scheme)://\(host):\(settings.socket_port)/"
		}()

		return [
			"name": Const.api_product_name,
			"version": Const.appVersion(),
			"api_version": Const.api_v1_version,
			"device": device,
			"battery": [
				"percentage": Const.getBatteryLevel(),
				"charging": state == .charging || state == .full,
			],
			"server": [
				"port": settings.server_port,
				"secure": settings.is_secure,
				"socket_port": settings.socket_port,
				"socket_subdirectory": subdir,
				"web_interface": settings.run_web_interface,
				"uptime": uptime(),
				"clients": connectedClientCount(),
				"sessions": ServerDelegate.sessions.count(),
			],
			"features": [
				"subjects_enabled": settings.subjects_enabled,
				"send_typing": settings.send_typing,
				"mark_when_read": settings.mark_when_read,
				"combine_contacts": settings.combine_contacts,
				"api_token_enabled": settings.api_token_enabled,
				"cors_enabled": settings.cors_enabled,
				"photos": true,
			],
			"defaults": [
				"chats": Int(settings.default_num_chats),
				"messages": Int(settings.default_num_messages),
				"photos": Int(settings.default_num_photos),
			],
			"theme": settings.themeName(),
			"tweak": tweakSummary(),
			"remote": [
				"enabled": settings.run_remote,
				"address": settings.remote_addr,
				"state": "\(starscream.socket_state)",
				"error": ServerDelegate.orNull(last_remote_error),
			],
			"websocket": [
				"url": socket_url,
				"events": [Const.ws_cmd_hello, Const.ws_cmd_new_message, Const.ws_cmd_typing, Const.ws_cmd_read, Const.ws_cmd_battery, Const.ws_cmd_pong],
			],
		]
	}

	func tweakInfo() -> [String: Any] {
		var summary = tweakSummary()
		summary["info"] = ServerDelegate.orNull(tweakPing())
		return summary
	}

	func routeAuth(_ parts: [String], method: CRHTTPMethod, req: CRRequest, res: CRResponse, ip: String, cors: [String: String]) throws {
		guard let action = parts.first, parts.count == 1 else {
			throw APIError.notFound("No such endpoint")
		}

		switch action {
			case "login":
				try requireMethod(method, oneOf: [.post])
				let body = ServerDelegate.jsonBody(req)
				let password = ServerDelegate.bodyString(body, "password") ?? ""

				guard !password.isEmpty, Settings.constantTimeEquals(password, settings.password) else {
					Const.log("event=auth.login.failed ip=\(ip)", warning: true)
					sleep(2)
					throw APIError.unauthorized()
				}

				ServerDelegate.rememberAddress(ip)
				let session = ServerDelegate.sessions.create()
				Const.log("event=auth.login.ok ip=\(ip)")
				sendJSON(res, [
					"token": session.token,
					"token_type": "Bearer",
					"expires_at": Int(session.expiresAt.timeIntervalSince1970),
					"expires_in": Int(session.expiresAt.timeIntervalSinceNow),
				], extra: cors)

			case "logout":
				try requireMethod(method, oneOf: [.post])
				let auth = try requireAuth(req, ip: ip)
				if auth.method == .session, let token = auth.token {
					ServerDelegate.sessions.revoke(token)
				}
				let body = ServerDelegate.jsonBody(req)
				let forget_ip = ServerDelegate.parseBool(req.query["all"], default: ServerDelegate.bodyBool(body, "all", default: false))
				if forget_ip {
					ServerDelegate.forgetAddress(ip)
				}
				Const.log("event=auth.logout ip=\(ip) method=\(auth.method.rawValue) all=\(forget_ip)")
				sendJSON(res, ["ok": true], extra: cors)

			case "session":
				try requireMethod(method, oneOf: [.get])
				let auth = ServerDelegate.authenticate(req)
				sendJSON(res, [
					"authenticated": auth.authenticated,
					"method": auth.method.rawValue,
					"expires_at": ServerDelegate.orNull(auth.expiresAt),
				], extra: cors)

			default:
				throw APIError.notFound("No such endpoint")
		}
	}

	func routeChats(_ parts: [String], method: CRHTTPMethod, req: CRRequest, res: CRResponse, ip: String, cors: [String: String]) throws {
		_ = try requireAuth(req, ip: ip)

		if parts.isEmpty {
			try requireMethod(method, oneOf: [.get])
			sendJSON(res, listChats(req), extra: cors)
			return
		}

		if parts.count == 1 && parts[0] == "pinned" {
			try requireMethod(method, oneOf: [.get])
			sendJSON(res, ["items": pinnedChats()], extra: cors)
			return
		}

		let chat_id = parts[0]
		guard !chat_id.isEmpty else {
			throw APIError.badRequest("chat_id is required")
		}

		if parts.count == 1 {
			try requireMethod(method, oneOf: [.get, .delete])
			if method == .get {
				let details = chat_delegate.getChatDetails(chat_id)
				guard !details.isEmpty else {
					throw APIError.notFound("Chat \(chat_id) not found")
				}
				sendJSON(res, ServerDelegate.decorateChat(details), extra: cors)
			} else {
				Const.log("event=chat.delete chat=\(chat_id) ip=\(ip)", warning: true)
				guard ServerDelegate.sender.removeObject(chat_id, text: nil) else {
					throw APIError.sendFailed("Messages refused to delete the chat")
				}
				sendJSON(res, ["ok": true], extra: cors)
			}
			return
		}

		guard parts.count == 2 else {
			throw APIError.notFound("No such endpoint")
		}

		switch parts[1] {
			case "messages":
				try requireMethod(method, oneOf: [.get, .post])
				if method == .get {
					let page = try listMessages(chat_id, req: req)
					sendJSON(res, page, extra: cors)
				} else {
					let accepted = try sendMessage(chat_id, req: req, ip: ip)
					sendJSON(res, status: 202, accepted, extra: cors)
				}

			case "read":
				try requireMethod(method, oneOf: [.post])
				Const.log("event=chat.read chat=\(chat_id)")
				guard ServerDelegate.sender.markConvo(asRead: chat_id) else {
					throw APIError.sendFailed("Messages refused to mark the chat as read")
				}
				sendJSON(res, ["ok": true], extra: cors)

			case "typing":
				try requireMethod(method, oneOf: [.post])
				guard settings.send_typing else {
					throw APIError.forbidden("Typing indicators are disabled in the app settings")
				}
				let body = ServerDelegate.jsonBody(req)
				let active = ServerDelegate.bodyBool(body, "active", default: ServerDelegate.parseBool(req.query["active"], default: true))
				Const.log("event=chat.typing chat=\(chat_id) active=\(active)")
				ServerDelegate.sender.sendTyping(active, forChat: chat_id)
				sendJSON(res, ["ok": true, "active": active], extra: cors)

			default:
				throw APIError.notFound("No such endpoint")
		}
	}

	func routeMessages(_ parts: [String], method: CRHTTPMethod, req: CRRequest, res: CRResponse, ip: String, cors: [String: String]) throws {
		_ = try requireAuth(req, ip: ip)

		if parts.isEmpty {
			try requireMethod(method, oneOf: [.post])
			let body = ServerDelegate.jsonBody(req)
			let chat_id = (ServerDelegate.bodyString(body, "chat_id") ?? ServerDelegate.bodyString(body, "chat") ?? req.query["chat_id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
			guard !chat_id.isEmpty else {
				throw APIError.badRequest("chat_id is required")
			}
			let accepted = try sendMessage(chat_id, req: req, ip: ip)
			sendJSON(res, status: 202, accepted, extra: cors)
			return
		}

		let guid = parts[0]
		guard !guid.isEmpty else {
			throw APIError.badRequest("guid is required")
		}
		let bare_guid = String(guid.suffix(36))

		if parts.count == 1 {
			try requireMethod(method, oneOf: [.get, .delete])
			if method == .get {
				let text = chat_delegate.getTextByGUID(bare_guid)
				guard !text.isEmpty else {
					throw APIError.notFound("Message \(guid) not found")
				}
				sendJSON(res, ServerDelegate.decorateMessage(text), extra: cors)
			} else {
				let chat = chat_delegate.getChatOfText(bare_guid)
				guard !chat.isEmpty else {
					throw APIError.notFound("Message \(guid) not found")
				}
				Const.log("event=message.delete guid=\(guid) chat=\(chat) ip=\(ip)", warning: true)
				guard ServerDelegate.sender.removeObject(chat, text: guid) else {
					throw APIError.sendFailed("Messages refused to delete the message")
				}
				sendJSON(res, ["ok": true], extra: cors)
			}
			return
		}

		guard parts.count == 2, parts[1] == "tapback" else {
			throw APIError.notFound("No such endpoint")
		}

		try requireMethod(method, oneOf: [.post, .delete])
		let body = ServerDelegate.jsonBody(req)
		let raw_type: Any? = body["type"] ?? (req.query["type"] as Any?)
		let type = try ServerDelegate.parseTapbackType(raw_type)
		let remove = method == .delete || ServerDelegate.bodyBool(body, "remove", default: ServerDelegate.parseBool(req.query["remove"], default: false))

		let chat = chat_delegate.getChatOfText(bare_guid)
		guard !chat.isEmpty else {
			throw APIError.notFound("Message \(guid) not found")
		}

		let reaction = 2000 + type + (remove ? 1000 : 0)
		Const.log("event=message.tapback guid=\(guid) type=\(type) remove=\(remove) chat=\(chat)")
		guard ServerDelegate.sender.sendTapback(reaction as NSNumber, forGuid: guid, inChat: chat) else {
			throw APIError.sendFailed("Messages refused to send the tapback")
		}
		sendJSON(res, ["ok": true, "type": type, "removed": remove], extra: cors)
	}

	static func parseTapbackType(_ raw: Any?) throws -> Int {
		if let number = raw as? NSNumber {
			let value = number.intValue
			guard (0...5).contains(value) else {
				throw APIError.badRequest("type must be between 0 and 5")
			}
			return value
		}
		if let string = raw as? String {
			let lowered = string.lowercased().trimmingCharacters(in: .whitespaces)
			if let value = Int(lowered) {
				guard (0...5).contains(value) else {
					throw APIError.badRequest("type must be between 0 and 5")
				}
				return value
			}
			if let index = Const.api_tapback_names.firstIndex(of: lowered) {
				return index
			}
		}
		throw APIError.badRequest("type is required", details: ["allowed": Const.api_tapback_names])
	}

	func routeContacts(_ parts: [String], method: CRHTTPMethod, req: CRRequest, res: CRResponse, ip: String, cors: [String: String]) throws {
		_ = try requireAuth(req, ip: ip)
		try requireMethod(method, oneOf: [.get])

		guard let first = parts.first else {
			throw APIError.notFound("No such endpoint")
		}

		if first == "match" && parts.count == 1 {
			let query = (req.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
			guard !query.isEmpty else {
				throw APIError.badRequest("q is required")
			}
			let type = (req.query["type"] ?? "address").lowercased()
			let items: Any = type == "name" ? chat_delegate.matchPartialName(query) : chat_delegate.matchPartialAddress(query)
			sendJSON(res, ["items": items, "type": type == "name" ? "name" : "address"], extra: cors)
			return
		}

		let chat_id = first
		if parts.count == 1 {
			let name = chat_delegate.getDisplayName(chat_id: chat_id)
			sendJSON(res, [
				"chat_id": chat_id,
				"display_name": name.isEmpty ? chat_id : name,
				"photo_url": ServerDelegate.contactPhotoURL(chat_id),
			], extra: cors)
			return
		}

		guard parts.count == 2, parts[1] == "photo" else {
			throw APIError.notFound("No such endpoint")
		}

		var data = chat_delegate.returnImageData(chat_id: chat_id)
		if data.isEmpty && ServerDelegate.parseBool(req.query["fallback"], default: false) {
			data = chat_delegate.returnImageData(chat_id: "default")
		}
		guard !data.isEmpty else {
			throw APIError.notFound("No photo for \(chat_id)")
		}

		var headers = cors
		headers["Cache-Control"] = "private, max-age=3600"
		sendBinary(res, data: data, mime: data.first == 0x89 ? "image/png" : "image/jpeg", extra: headers)
	}

	func listChats(_ req: CRRequest) -> [String: Any] {
		let fallback = Int(settings.default_num_chats) > 0 ? Int(settings.default_num_chats) : 40
		var limit = ServerDelegate.parseInt(req.query["limit"]) ?? fallback
		if limit <= 0 { limit = fallback }
		limit = min(limit, Const.api_max_chat_limit)
		let offset = max(0, ServerDelegate.parseInt(req.query["offset"]) ?? 0)

		let chats = chat_delegate.loadChats(num_to_load: limit, offset: offset).map({ ServerDelegate.decorateChat($0) })
		let has_more = chats.count >= limit

		Const.log("event=chats.list limit=\(limit) offset=\(offset) count=\(chats.count)")

		return [
			"items": chats,
			"limit": limit,
			"offset": offset,
			"count": chats.count,
			"has_more": has_more,
			"next_offset": ServerDelegate.orNull(has_more ? offset + limit : nil),
		]
	}

	func pinnedChats() -> [String] {
		#if os(iOS)
		guard Const.getOSVersion() >= 14.0 else { return [String]() }
		return chat_delegate.getPinnedChats() ?? [String]()
		#else
		return [String]()
		#endif
	}

	func countMessages(chat: String, from: Int, newerThan: Int?, atOrNewerThan: Int?) -> Int {
		var db = chat_delegate.createConnection()
		guard db != nil else { return 0 }
		defer { chat_delegate.closeDatabase(&db) }

		let ids = chat.split(separator: ",").map({ String($0) })
		let placeholders = ids.map({ _ in "chat_identifier is ?" }).joined(separator: " or ")
		var condition = "where m.ROWID in (select message_id from chat_message_join where chat_id in (select ROWID from chat where \(placeholders)))"
		var args: [Any] = ids

		if from == 1 || from == 2 {
			condition += " and m.is_from_me is \(from == 1 ? 1 : 0)"
		}
		if let newer = newerThan {
			condition += " and m.date > CAST(? AS INTEGER)"
			args.append(String(newer))
		}
		if let at_or_newer = atOrNewerThan {
			condition += " and m.date >= CAST(? AS INTEGER)"
			args.append(String(at_or_newer))
		}

		let rows = chat_delegate.selectFromSql(db: db, columns: ["count(m.ROWID)"], table: "message m", condition: condition, args: args)
		return Int(rows.first?["count(m.ROWID)"] ?? "0") ?? 0
	}

	func listMessages(_ chat_id: String, req: CRRequest) throws -> [String: Any] {
		let fallback = Int(settings.default_num_messages) > 0 ? Int(settings.default_num_messages) : 100
		var limit = ServerDelegate.parseInt(req.query["limit"]) ?? fallback
		if limit <= 0 { limit = fallback }
		limit = min(limit, Const.api_max_list_limit)
		let offset = max(0, ServerDelegate.parseInt(req.query["offset"]) ?? 0)

		let from: Int = {
			switch (req.query["from"] ?? "all").lowercased() {
				case "me", "1": return 1
				case "them", "2": return 2
				default: return 0
			}
		}()

		var before: Int? = nil
		if let raw = req.query["before"], !raw.isEmpty {
			guard let value = Int(raw) else { throw APIError.badRequest("before must be an integer timestamp") }
			before = value
		}
		var after: Int? = nil
		if let raw = req.query["after"], !raw.isEmpty {
			guard let value = Int(raw) else { throw APIError.badRequest("after must be an integer timestamp") }
			after = value
		}

		let explicit_read = req.query["mark_read"]
		let should_mark = explicit_read != nil
			? ServerDelegate.parseBool(explicit_read, default: false)
			: (settings.mark_when_read && offset == 0 && before == nil)

		if should_mark {
			let marked = ServerDelegate.sender.markConvo(asRead: chat_id)
			Const.log("event=chat.read chat=\(chat_id) ok=\(marked) source=messages")
		}

		var skip = offset
		var window: Int? = nil

		if let before = before {
			skip += countMessages(chat: chat_id, from: from, newerThan: nil, atOrNewerThan: before)
		}
		if let after = after {
			window = countMessages(chat: chat_id, from: from, newerThan: after, atOrNewerThan: nil)
		}

		var fetch = limit
		if let window = window {
			fetch = max(0, min(limit, window - skip))
		}

		var items = [[String: Any]]()
		if fetch > 0 {
			items = chat_delegate.loadMessages(num: chat_id, num_items: fetch, offset: skip, from: from)
		}

		if let before = before {
			items = items.filter({ ($0["date"] as? Int ?? 0) < before })
		}
		if let after = after {
			items = items.filter({ ($0["date"] as? Int ?? 0) > after })
		}

		let decorated = items.map({ ServerDelegate.decorateMessage($0, chat: chat_id) })
		let dates = items.compactMap({ $0["date"] as? Int })
		let has_more: Bool = {
			if let window = window {
				return skip + items.count < window
			}
			return items.count >= limit
		}()

		Const.log("event=messages.list chat=\(chat_id) limit=\(limit) offset=\(offset) before=\(before ?? -1) after=\(after ?? -1) count=\(items.count)")

		return [
			"items": decorated,
			"limit": limit,
			"offset": offset,
			"count": decorated.count,
			"has_more": has_more,
			"next_before": ServerDelegate.orNull(has_more ? dates.min() : nil),
			"newest_date": ServerDelegate.orNull(dates.max()),
		]
	}

	func listSenders() throws -> [[String: Any]] {
		guard let raw = ServerDelegate.sender.getSenders() else {
			Const.log("event=senders.list.failed reason=tweak_unreachable", warning: true)
			throw APIError.tweakUnreachable("The Messages tweak in SpringBoard did not return the sender addresses. Respring the device or reinstall libsmserver 0.9.3 or later.")
		}
		let items = raw.compactMap({ $0 as? [String: Any] })
		Const.log("event=senders.list count=\(items.count)")
		return items
	}

	static let imessageStatusMaxAddresses = 25

	static func statusAddresses(_ req: CRRequest) -> [String] {
		let body = jsonBody(req)
		var raw = [String]()
		if let list = body["addresses"] as? [Any] {
			raw += list.compactMap({ $0 as? String })
		}
		for key in ["addresses", "address"] {
			if let joined = body[key] as? String {
				raw += joined.split(separator: ",").map({ String($0) })
			}
			if let joined = req.query[key] {
				raw += joined.split(separator: ",").map({ String($0) })
			}
		}
		var seen = Set<String>()
		return raw.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty && seen.insert($0).inserted })
	}

	func imessageStatus(_ addresses: [String]) throws -> [String: Any] {
		guard !addresses.isEmpty else {
			throw APIError.badRequest("Provide at least one address (`address` query parameter, comma separated, or `addresses` in a JSON body)")
		}
		guard addresses.count <= ServerDelegate.imessageStatusMaxAddresses else {
			throw APIError.badRequest("At most \(ServerDelegate.imessageStatusMaxAddresses) addresses per request", details: ["count": addresses.count, "max": ServerDelegate.imessageStatusMaxAddresses])
		}
		guard let result = ServerDelegate.sender.getIMessageStatus(addresses) as? [String: Any] else {
			Const.log("event=imessage_status.failed reason=tweak_unreachable count=\(addresses.count)", warning: true)
			throw APIError.tweakUnreachable("The Messages tweak in SpringBoard did not answer. Respring the device or reinstall libsmserver 0.9.3 or later.")
		}
		guard result["ok"] as? Bool ?? false else {
			let reason = result["reason"] as? String ?? "unknown"
			Const.log("event=imessage_status.failed reason=\(reason) count=\(addresses.count)", warning: true)
			throw APIError(502, "lookup_failed", "Messages could not look up iMessage availability (\(reason)).")
		}
		let items: [[String: Any]] = (result["items"] as? [Any] ?? []).compactMap({ raw in
			guard var item = raw as? [String: Any] else { return nil }
			for key in ["normalized", "imessage"] where item[key] == nil {
				item[key] = NSNull()
			}
			return item
		})
		let timed_out = result["timed_out"] as? Bool ?? false
		Const.log("event=imessage_status count=\(items.count) timed_out=\(timed_out) elapsed_ms=\(result["elapsed_ms"] as? Int ?? -1)")
		return ["items": items, "count": items.count, "timed_out": timed_out]
	}

	func sendMessage(_ chat_id: String, req: CRRequest, ip: String) throws -> [String: Any] {
		let body = ServerDelegate.jsonBody(req)
		let text = ServerDelegate.bodyString(body, "text") ?? ""
		let subject = ServerDelegate.bodyString(body, "subject") ?? ""
		let from = (ServerDelegate.bodyString(body, "from") ?? req.query["from"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let service = ServerDelegate.bodyString(body, "service") ?? req.query["service"] ?? ""
		guard service.isEmpty || service == "iMessage" || service == "SMS" else {
			throw APIError.badRequest("service must be iMessage or SMS")
		}

		var photos = [String]()
		if let list = body["photos"] as? [Any] {
			photos = list.compactMap({ $0 as? String }).filter({ !$0.isEmpty })
		} else if let joined = ServerDelegate.bodyString(body, "photos") {
			photos = joined.split(separator: ":").map({ String($0) }).filter({ !$0.isEmpty })
		}

		var files = collectUploadedFiles(req)
		files.append(contentsOf: writeInlineAttachments(body))

		guard !text.isEmpty || !subject.isEmpty || !photos.isEmpty || !files.isEmpty else {
			throw APIError.badRequest("Provide text, subject, photos or at least one attachment")
		}

		var params: [String: Any] = ["text": text, "subject": subject, "chat": chat_id]
		if !photos.isEmpty {
			params["photos"] = photos.joined(separator: ":")
		}
		if !from.isEmpty {
			params["from"] = from
		}
		if !service.isEmpty {
			params["service"] = service
		}

		Const.log("event=message.send chat=\(chat_id) text_len=\(text.count) subject_len=\(subject.count) photos=\(photos.count) files=\(files.count) from_given=\(!from.isEmpty) ip=\(ip)")

		let outcome = ServerDelegate.sendText(params: params, new_files: files)
		if outcome.isSenderProblem {
			let available = ((try? listSenders()) ?? []).compactMap({ $0["address"] as? String })
			Const.log("event=message.send.invalid_sender chat=\(chat_id) reason=\(outcome.reason ?? "none") available=\(available.count)", warning: true)
			var details: [String: Any] = ["reason": outcome.reason ?? "sender_unavailable", "from": from, "available": available]
			if let current = outcome.from {
				details["current"] = current
			}
			throw APIError.invalidSender(ServerDelegate.sendFailureMessage(outcome.reason), details: details)
		}
		if outcome.reason == "service_mismatch" {
			throw APIError(409, "service_mismatch", "This conversation would be sent over \(outcome.service ?? "another service"), not \(service). Nothing was sent.", details: ["required": service, "current": ServerDelegate.orNull(outcome.service)])
		}
		switch outcome.code {
			case 200:
				return ["ok": true, "accepted": true, "chat_id": chat_id, "attachments": files.count + photos.count, "from": ServerDelegate.orNull(outcome.from), "service": ServerDelegate.orNull(outcome.service)]
			case 400:
				throw APIError.badRequest("Nothing to send")
			default:
				throw APIError.sendFailed(ServerDelegate.sendFailureMessage(outcome.reason))
		}
	}

	func writeInlineAttachments(_ body: [String: Any]) -> [String] {
		guard let inline = body["attachments_base64"] as? [[String: Any]], !inline.isEmpty else {
			return [String]()
		}

		let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smserver_inline_\(UUID().uuidString)", isDirectory: true)
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
		} catch {
			Const.log("event=upload.inline.dir_failed error=\(error)", warning: true)
			return [String]()
		}

		var written = [String]()
		for (index, item) in inline.enumerated() {
			guard let encoded = item["data"] as? String, let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else {
				Const.log("event=upload.inline.decode_failed index=\(index)", warning: true)
				continue
			}
			let raw_name = (item["filename"] as? String ?? item["name"] as? String ?? "attachment_\(index)")
			let name = raw_name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
			let target = directory.appendingPathComponent(name.isEmpty ? "attachment_\(index)" : name)
			if FileManager.default.createFile(atPath: target.path, contents: data, attributes: nil) {
				written.append(target.path)
			} else {
				Const.log("event=upload.inline.write_failed path=\(target.path)", warning: true)
			}
		}

		Const.log("event=upload.inline.written count=\(written.count)")
		return written
	}

	func searchMessages(_ req: CRRequest) throws -> [String: Any] {
		let term = (req.query["q"] ?? req.query["search"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !term.isEmpty else {
			throw APIError.badRequest("q is required")
		}

		let case_sensitive = ServerDelegate.parseBool(req.query["case_sensitive"], default: false)
		let bridge_gaps = ServerDelegate.parseBool(req.query["bridge_gaps"], default: true)
		let group = (req.query["group"] ?? "time").lowercased() == "chat" ? "chat" : "time"

		let raw = chat_delegate.searchForString(term: term, case_sensitive: case_sensitive, bridge_gaps: bridge_gaps, group_by_time: group == "time")
		let result = raw as? [String: Any] ?? [String: Any]()

		var items = [[String: Any]]()
		var chats = [String: [[String: Any]]]()
		let contacts = result["conversations"] as? [[String: String]] ?? [[String: String]]()

		for (key, value) in result where key != "conversations" {
			guard let texts = value as? [[String: Any]] else { continue }
			let decorated = texts.map({ ServerDelegate.decorateMessage($0) })
			if key == "texts" {
				items = decorated
			} else {
				chats[key] = decorated
			}
		}

		Const.log("event=search q_len=\(term.count) group=\(group) items=\(items.count) chats=\(chats.count)")

		return [
			"query": term,
			"group": group,
			"case_sensitive": case_sensitive,
			"bridge_gaps": bridge_gaps,
			"items": items,
			"chats": chats,
			"contacts": contacts,
		]
	}

	static func sanitizeRelativePath(_ raw: String) throws -> String {
		let normalized = raw.replacingOccurrences(of: "\\", with: "/")
		let segments = normalized.split(separator: "/", omittingEmptySubsequences: true).map({ String($0) })
		guard !segments.isEmpty, !segments.contains(".."), !segments.contains(".") else {
			throw APIError.badRequest("Invalid path")
		}
		return segments.joined(separator: "/")
	}

	enum ByteRange {
		case whole
		case partial(Int, Int)
		case unsatisfiable
	}

	static func parseRange(_ header: String?, total: Int) -> ByteRange {
		guard let header = header?.trimmingCharacters(in: .whitespaces), header.lowercased().hasPrefix("bytes=") else {
			return .whole
		}
		let spec = String(header.dropFirst("bytes=".count))
		guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else {
			return .unsatisfiable
		}
		let start_text = String(spec[spec.startIndex..<dash])
		let end_text = String(spec[spec.index(after: dash)...])

		if start_text.isEmpty {
			guard let suffix = Int(end_text), suffix > 0, total > 0 else { return .unsatisfiable }
			let length = min(suffix, total)
			return .partial(max(0, total - length), total - 1)
		}

		guard let start = Int(start_text), start >= 0, start < total else { return .unsatisfiable }
		var end = total - 1
		if !end_text.isEmpty {
			guard let requested = Int(end_text), requested >= start else { return .unsatisfiable }
			end = min(requested, total - 1)
		}
		return .partial(start, end)
	}

	func serveAttachment(_ raw_path: String, req: CRRequest, res: CRResponse, cors: [String: String]) throws {
		let path = try ServerDelegate.sanitizeRelativePath(raw_path)
		let info = chat_delegate.getAttachmentDataFromPath(path: path)

		guard let data = info.first as? Data, !data.isEmpty else {
			throw APIError.notFound("No attachment at \(path)")
		}

		let stored_mime = (info.count > 1 ? info[1] as? String : nil).flatMap({ $0.isEmpty ? nil : $0 }) ?? "application/octet-stream"
		let mime = stored_mime.lowercased() == "image/heic" && data.starts(with: [0xFF, 0xD8]) ? "image/jpeg" : stored_mime
		let filename = path.split(separator: "/").last.map({ String($0) }) ?? "attachment"
		let download = ServerDelegate.parseBool(req.query["download"], default: false)
		let ascii_name = filename.replacingOccurrences(of: "\"", with: "'")
		let encoded_name = ServerDelegate.encodeSegment(filename)

		var headers = cors
		headers["Accept-Ranges"] = "bytes"
		headers["Cache-Control"] = "private, max-age=3600"
		headers["Content-Disposition"] = "\(download ? "attachment" : "inline"); filename=\"\(ascii_name)\"; filename*=UTF-8''\(encoded_name)"

		let total = data.count
		switch ServerDelegate.parseRange(req.value(forHTTPHeaderField: "Range"), total: total) {
			case .unsatisfiable:
				res.setStatusCode(416, description: "Range Not Satisfiable")
				headers["Content-Range"] = "bytes */\(total)"
				sendBinary(res, data: Data(), mime: mime, extra: headers)
			case .partial(let start, let end):
				let slice = data.subdata(in: start..<(end + 1))
				res.setStatusCode(206, description: "Partial Content")
				headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
				Const.log("event=attachment.range path=\(path) start=\(start) end=\(end) total=\(total)")
				sendBinary(res, data: slice, mime: mime, extra: headers)
			case .whole:
				Const.log("event=attachment.full path=\(path) bytes=\(total) mime=\(mime)")
				sendBinary(res, data: data, mime: mime, extra: headers)
		}
	}

	func listPhotos(_ req: CRRequest) throws -> [String: Any] {
		let fallback = Int(settings.default_num_photos) > 0 ? Int(settings.default_num_photos) : 40
		var limit = ServerDelegate.parseInt(req.query["limit"]) ?? fallback
		if limit <= 0 { limit = fallback }
		limit = min(limit, Const.api_max_list_limit)
		let offset = max(0, ServerDelegate.parseInt(req.query["offset"]) ?? 0)
		let recent = ServerDelegate.parseBool(req.query["recent"], default: true)

		let photos = chat_delegate.getPhotoList(num: limit, offset: offset, most_recent: recent)
			.filter({ !($0["URL"] as? String ?? "").isEmpty })
			.map({ photo -> [String: Any] in
				let path = photo["URL"] as? String ?? ""
				return [
					"path": path,
					"is_favorite": photo["is_favorite"] as? Bool ?? false,
					"url": ServerDelegate.photoURL(path),
				]
			})
		let has_more = photos.count >= limit

		Const.log("event=photos.list limit=\(limit) offset=\(offset) count=\(photos.count)")

		return [
			"items": photos,
			"limit": limit,
			"offset": offset,
			"count": photos.count,
			"has_more": has_more,
			"next_offset": ServerDelegate.orNull(has_more ? offset + limit : nil),
		]
	}

	func servePhoto(_ raw_path: String, res: CRResponse, cors: [String: String]) throws {
		let path = try ServerDelegate.sanitizeRelativePath(raw_path)
		#if os(iOS)
		let data = chat_delegate.getPhotoDatafromPath(path: path)
		#else
		let data = Data()
		#endif
		guard !data.isEmpty else {
			throw APIError.notFound("No photo at \(path)")
		}
		var headers = cors
		headers["Cache-Control"] = "private, max-age=3600"
		Const.log("event=photo.serve path=\(path) bytes=\(data.count)")
		sendBinary(res, data: data, mime: "image/jpeg", extra: headers)
	}

	static func sendFailureMessage(_ reason: String?) -> String {
		switch reason ?? "" {
			case "imessage_unavailable": return "iMessage is not active on this iPhone, and this conversation can only be reached over iMessage. Turn on iMessage in Settings > Messages."
			case "no_sms_account": return "iMessage is not active and no SMS account is available on this iPhone."
			case "springboard_unreachable": return "The Messages tweak in SpringBoard is not reachable. Respring the device or reinstall libsmserver."
			case "daemon_unavailable": return "SpringBoard could not connect to the Messages daemon (imagent)."
			case "attachment_unreadable": return "The attachment could not be read on the device."
			case "compose_failed", "no_chat", "no_conversation": return "Messages could not create a conversation for this recipient."
			case "chat_not_found": return "This group conversation does not exist on the iPhone."
			case "missing_address": return "No recipient was given."
			case "empty_message": return "Nothing to send."
			case "sender_unavailable": return "`from` is not one of this iPhone's iMessage or SMS addresses. GET /api/v1/senders lists them."
			case "sender_requires_imessage": return "This conversation is sent over SMS, which always uses the SIM number. Use that number as `from` or leave it out."
			case "sender_locked_group": return "Group conversations keep the address they were started from. Changing it would split the group for the other members."
			case "sender_unsupported": return "Messages did not accept the sender address for this conversation."
			default: return "Messages refused to send the message (\(reason ?? "unknown"))."
		}
	}

	static func sendText(params: [String:Any], new_files: [String]) -> SendOutcome {
		var body: String = params["text"] as? String ?? ""
		let address: String = params["chat"] as? String ?? ""
		var subject: String = params["subject"] as? String ?? ""
		let from: String = (params["from"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let service: String = params["service"] as? String ?? ""
		var files = new_files

		#if os(iOS)
		if let photos = params["photos"] as? String {
			for i in photos.split(separator: ":") {
				files.append(Const.photo_address_prefix + String(i))
			}
		}
		#endif

		if subject.count > 0 && body.count == 0 && files.count == 0 {
			body = subject
			subject = ""
		}

		guard !address.isEmpty else {
			Const.log("event=message.send.rejected reason=missing_chat")
			return SendOutcome(code: 400, reason: nil, service: nil, from: nil)
		}

		guard body.count + files.count + subject.count > 0 else {
			return SendOutcome(code: 400, reason: nil, service: nil, from: nil)
		}

		let result = ServerDelegate.sender.sendText(body, subject: subject, toAddress: address, from: from.isEmpty ? nil : from, service: service.isEmpty ? nil : service, attachments: files) ?? [AnyHashable: Any]()
		let ok = result["ok"] as? Bool ?? false
		let outcome = SendOutcome(
			code: ok ? 200 : 503,
			reason: ok ? nil : (result["reason"] as? String ?? "unknown"),
			service: result["service"] as? String,
			from: result["from"] as? String
		)
		let code = outcome.isSenderProblem ? 400 : outcome.code
		Const.log("event=message.send.ipc chat=\(address) ok=\(ok) reason=\(outcome.reason ?? "none") service=\(outcome.service ?? "none") from_given=\(!from.isEmpty) from_reported=\(outcome.from != nil) files=\(files.count)")
		return SendOutcome(code: code, reason: outcome.reason, service: outcome.service, from: outcome.from)
	}

	static func sendGetRequest(params: [String:String]) -> (Int, String) {
		let chat_delegate = ChatDelegate.shared()

		if Const.api_tap_vals.contains(params.keys.first ?? "") {
			guard let req = params[Const.api_tap_req], let guid = params[Const.api_tap_guid] else {
				return (400, "Please include parameters '\(Const.api_tap_req)' and '\(Const.api_tap_guid)' in your request")
			}

			var reaction: Int = (Int(req) ?? -1) + 2000
			let remove = (params[Const.api_tap_rem] ?? "false") == "true"
			let chat = chat_delegate.getChatOfText(String(guid.suffix(36)))

			guard reaction < 2006 && reaction > 1999 else {
				return (400, "tapback value must be at least 0 and no greater than 5")
			}

			if remove { reaction += 1000 }

			let ret = ServerDelegate.sender.sendTapback(reaction as NSNumber, forGuid: guid, inChat: chat)

			if !ret {
				return (503, "Could not send tapback; unknown reason")
			}

			return (200, "")
		} else if params.keys.first == Const.api_del_chat {
			guard let chat = params[Const.api_del_chat], chat.count > 0 else {
				return (400, "Please specify the chat_identifier")
			}

			let ret = ServerDelegate.sender.removeObject(chat, text: nil)

			if !ret {
				return (503, "Failed to delete chat; unknown reason")
			}

			return (200, "")
		} else if params.keys.first == Const.api_del_text {
			guard let text = params[Const.api_del_text], text.count > 0 else {
				return (400, "Please specify the text guid")
			}

			let chat = chat_delegate.getChatOfText(String(text.suffix(36)))

			let ret = ServerDelegate.sender.removeObject(chat, text: text)

			if !ret {
				return (503, "Failed to delete text; unknown reason")
			}

			return (200, "")
		}

		return (406, "No api endpoint exists for url query parameters")
	}

	static func parseAndReturn(params: [String:String], address: String = "", verify_auth: Bool = true, token: String? = nil) -> (Int, Any) {
		let settings = Settings.shared()
		let chat_delegate = ChatDelegate.shared()

		Const.log("event=legacy.parse keys=\(params.keys.sorted().joined(separator: ","))")

		if params.keys.first == "password" {
			if let password = params.values.first, Settings.constantTimeEquals(password, settings.password) {
				rememberAddress(address)
				Const.log("event=auth.login.ok ip=\(address) source=legacy")
				return (200, "true")
			}

			Const.log("event=auth.login.failed ip=\(address) source=legacy", warning: true)
			sleep(2)

			return (200, "false")
		}

		if verify_auth && !authenticate(ip: address, token: token).authenticated {
			return (403, "Please authenticate")
		}

		let f = (params.keys.first ?? "") as String

		if Const.api_msg_vals.contains(f) {
			var person = params[Const.api_msg_req] ?? ""

			if (params[Const.api_msg_read] == nil && settings.mark_when_read) || (params[Const.api_msg_read] != nil && params[Const.api_msg_read] == "true") {
				_ = ServerDelegate.sender.markConvo(asRead: person)
			}

			let num_texts = UInt(params[Const.api_msg_num] ?? String(settings.default_num_messages)) ?? settings.default_num_messages
			let offset = Int(params[Const.api_msg_off] ?? "0") ?? 0
			let from = Int(params[Const.api_msg_from] ?? "0") ?? 0
			person = person.replacingOccurrences(of: "\"", with: "")

			let texts_array = chat_delegate.loadMessages(num: person, num_items: Int(num_texts), offset: offset, from: from)

			return (200, texts_array)
		} else if Const.api_chat_vals.contains(f) {
			let chats_offset = Int(params[Const.api_chat_off] ?? "0") ?? 0
			let num_chats = UInt(params[Const.api_chat_req] ?? String(settings.default_num_chats)) ?? settings.default_num_chats

			let chats_array = chat_delegate.loadChats(num_to_load: Int(num_chats), offset: chats_offset)

			return (200, chats_array)
		} else if f == Const.api_name_req {
			let chat_id = params[Const.api_name_req] ?? ""
			let name = chat_delegate.getDisplayName(chat_id: chat_id)

			return (200, name)
		} else if Const.api_search_vals.contains(f) {
			let case_sensitive = (params[Const.api_search_case] ?? "false") == "true"
			let bridge_gaps = (params[Const.api_search_bridge] ?? "true") == "true"
			let group_by_time = (params[Const.api_search_group] ?? "time") == "time"
			let term = params[Const.api_search_req] ?? ""

			let matches = chat_delegate.searchForString(term: term , case_sensitive: case_sensitive, bridge_gaps: bridge_gaps, group_by_time: group_by_time)

			return (200, matches)
		} else if Const.api_photo_vals.contains(f) {
			let most_recent = (params[Const.api_photo_recent] ?? "true") == "true"
			let offset = Int(params[Const.api_photo_off] ?? "0") ?? 0
			let num = UInt(params[Const.api_photo_req] ?? String(settings.default_num_photos)) ?? settings.default_num_photos

			let photos = chat_delegate.getPhotoList(num: Int(num), offset: offset, most_recent: most_recent)

			return (200, photos)
		} else if f == Const.api_config {
			var subdir: String? = nil
			if let subdirectory = settings.socket_subdirectory {
				subdir = subdirectory
				if subdirectory.prefix(1) == "/" { subdir = String(subdirectory.suffix(subdirectory.count - 1)) }
				if subdirectory.suffix(1) != "/" { subdir! += "/" }
			}

			let config: [String:Any?] = [
				"socket_port": settings.socket_port,
				"socket_subdirectory": subdir,
				"debug": settings.debug,
				"subjects": settings.subjects_enabled,
			]

			return (200, config)
		} else if Const.api_match_vals.contains(f) {
			guard let id = params[Const.api_match_keyword], let type = params[Const.api_match_type] else {
				return (400, "Please specify the identifier and type with \(Const.api_match_keyword) and \(Const.api_match_type)")
			}

			let result = type == "chat" ? chat_delegate.matchPartialAddress(id) : chat_delegate.matchPartialName(id)

			return (200, result)
		} else if f == Const.api_convo_req {
			guard let chat_id = params[Const.api_convo_req], chat_id.count > 0 else {
				return (400, "Please include a chat_identifier")
			}

			let res = chat_delegate.getChatDetails(chat_id)

			return (200, res)
		}

		Const.log("event=legacy.unknown keys=\(params.keys.sorted().joined(separator: ","))", warning: true)
		return (404, "There is no functionality in the API that implements these URL query parameters")
	}

	static func parseDataRequest(_ req: CRRequest, res: CRResponse) {
		let chat_delegate = ChatDelegate.shared()

		let f = req.query.keys.first

		if f == "chat_id" {
			let q = req.query
			let data = chat_delegate.returnImageData(chat_id: q["chat_id"] ?? "")

			var mime = "image/jpeg"
			if !data.isEmpty {
				var bytes: UInt8 = 0
				data.copyBytes(to: &bytes, count: 1)

				if bytes == 0x89 {
					mime = "image/png"
				}
			}

			res.setValue(mime, forHTTPHeaderField: "Content-Type")
			if data.isEmpty { res.setStatusCode(404, description: "No profile image for chat_id \(q["chat_id"] ?? "")") }
			res.send(data)
		} else if f == "path" {
			let info = chat_delegate.getAttachmentDataFromPath(path: req.query["path"] ?? "")

			if let attData = info[0] as? Data, !attData.isEmpty {
				if let type = info[1] as? String {
					res.setValue(type, forHTTPHeaderField: "Content-Type")
				}
				res.setValue("inline; filename=\(req.query["path"]?.split(separator: "/").last ?? "")", forHTTPHeaderField: "Content-Disposition")

				if req.range != nil {
					res.setStatusCode(206, description: "Partial Content")
					res.setValue("bytes 0-\(attData.count - 1)/\(attData.count)", forHTTPHeaderField: "Content-Range")
				}
			} else {
				res.setStatusCode(404, description: "No attachment was found for this path")
			}

			res.send(info[0] as? Data ?? Data())
		} else if f == "photo" {
			#if os(iOS)
			res.setValue("image/png", forHTTPHeaderField: "Content-Type")
			let data = chat_delegate.getPhotoDatafromPath(path: req.query["photo"] ?? "")

			if data.isEmpty {
				res.setStatusCode(404, description: "No photo exists at the specified URL")
			}
			#elseif os(macOS)
			let data = Data()
			#endif

			res.send(data)
		} else {
			res.setStatusCode(404, description: "There is no functionality in the API that implements these URL query parameters")
			res.send("")
		}
	}

	func sentOrReceivedNewText(_ guid: String) {
		if settings.displayed_messages.contains(guid) { return }
		settings.displayed_messages.append(guid);

		let text = self.chat_delegate.getTextByGUID(guid);
		guard !text.isEmpty else {
			Const.log("event=socket.new_message.missing guid=\(guid)", warning: true)
			return
		}
		let decorated = ServerDelegate.decorateMessage(text)

		Const.log("event=socket.new_message guid=\(guid) from_me=\(decorated["is_from_me"] as? Bool ?? false) clients=\(connectedClientCount())")

		if server.isListening && socket.server?.webSocketCount ?? 0 > 0 {
			socket.sendNewText(info: decorated)
		}

		switch starscream.socket_state {
			case .Connected:
				starscream.sendNewMessage(decorated)
			default:
				break
		}
	}

	func sentTapback(_ tapback: Int32, guid: String) {
		guard server.isListening && socket.server?.webSocketCount ?? 0 > 0 else { return }

		let tb = self.chat_delegate.getTapbackInformation(tapback, guid: guid)
		guard !tb.isEmpty else {
			Const.log("event=socket.tapback.missing guid=\(guid) type=\(tapback)", warning: true)
			return
		}

		Const.log("event=socket.tapback guid=\(guid) type=\(tapback)")
		socket.sendNewText(info: ServerDelegate.decorateMessage(tb))
	}

	func setPartyTyping(_ vals: [String:Any]) {
		if let chat = vals["chat"] as? String, let typing = vals["typing"] as? NSNumber {
			Const.log("event=socket.typing chat=\(chat) active=\(typing == 1)")
			self.socket.sendTyping(chat, typing: typing == 1)
			self.starscream.sendTyping(chat, typing: typing == 1)
		}
	}

	func setTextRead(_ guid: String) {
		if settings.read_messages.contains(guid) { return }
		settings.read_messages.append(guid)

		let text = self.chat_delegate.getTextByGUID(guid)
		let date_read = text["date_read"] as? Int ?? 0
		let date = Const.getRelativeTime(ts: Double(date_read))

		Const.log("event=socket.read guid=\(guid) date_read=\(date_read)")
		self.socket.sendTextRead(guid, date: date, dateRead: date_read)
	}
}
