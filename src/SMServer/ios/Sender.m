#import <Foundation/Foundation.h>
#import "Sender.h"
#import "../../../libsmserver/SMSIPC.h"

#define SMSAppLog(fmt, ...) NSLog(@"[SMServer] pid=%d " fmt, getpid(), ##__VA_ARGS__)

static double const SMSSendTimeout = 60.0;
static double const SMSDefaultTimeout = 15.0;
static double const SMSTypingTimeout = 5.0;
static double const SMSPingTimeout = 8.0;
static double const SMSIDStatusTimeout = 20.0;

static id SMSCallSpringBoard(NSString *method, id args, double timeout) {
	NSError *error = nil;
	id result = SMSIPCCall(SMSIPC_SPRINGBOARD_SOCKET, method, args, timeout, &error);
	if (error) {
		SMSAppLog(@"event=springboard_call_failed method=%@ error=\"%@\"", method, error.localizedDescription);
	}
	return result;
}

static BOOL SMSBoolResult(id result) {
	if ([result isKindOfClass:[NSDictionary class]]) return [result[@"ok"] boolValue];
	return [result isKindOfClass:[NSNumber class]] && [result boolValue];
}

@implementation IPCTextWatcher {
	dispatch_source_t _server;
}

+ (instancetype)sharedInstance {
	static dispatch_once_t onceToken = 0;
	__strong static IPCTextWatcher* sharedInstance = nil;
	dispatch_once(&onceToken, ^{
		sharedInstance = [[self alloc] init];
	});
	return sharedInstance;
}

- (instancetype)init {
	if ((self = [super init])) {
		_setTexts = ^(NSString *guid) {};
		_setTyping = ^(NSDictionary *vals) {};
		_sentTapback = ^(int tapback, NSString *guid) {};
		_textRead = ^(NSString *guid) {};
		__weak IPCTextWatcher *weakSelf = self;
		_server = SMSIPCStartManagedServer(SMSIPC_APP_SOCKET, 10.0, 10.0, ^id(NSString *method, id args) {
			return [weakSelf handleEvent:method args:args];
		});
		SMSAppLog(@"event=event_listener_started listening=%d path=%@", _server != nil, SMSIPC_APP_SOCKET);
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
			id result = SMSCallSpringBoard(@"ping", nil, SMSPingTimeout);
			NSDictionary *state = [result isKindOfClass:[NSDictionary class]] ? result : nil;
			SMSAppLog(@"event=springboard_warmup reachable=%d version=%@ connected=%@", state != nil, state[@"version"], state[@"connected"]);
		});
	}
	return self;
}

- (BOOL)isListening {
	return _server != nil && SMSIPCSocketInode(SMSIPC_APP_SOCKET) != 0;
}

- (id)handleEvent:(NSString *)method args:(id)args {
	SMSAppLog(@"event=springboard_event method=%@", method);
	if ([method isEqualToString:@"ping"]) return @{@"pid": @(getpid())};
	if ([method isEqualToString:@"handleReceivedText"] && [args isKindOfClass:[NSString class]]) {
		[self handleReceivedTextWithCallback:args];
		return @YES;
	}
	if ([method isEqualToString:@"handlePartyTyping"] && [args isKindOfClass:[NSDictionary class]]) {
		[self handlePartyTypingWithCallback:args];
		return @YES;
	}
	if ([method isEqualToString:@"handleSentTapback"] && [args isKindOfClass:[NSDictionary class]]) {
		[self handleSentTapbackWithCallback:args];
		return @YES;
	}
	if ([method isEqualToString:@"handleTextRead"] && [args isKindOfClass:[NSString class]]) {
		[self handleTextReadWithCallback:args];
		return @YES;
	}
	SMSAppLog(@"event=springboard_event_ignored method=%@ args_class=%@", method, NSStringFromClass([args class]));
	return @NO;
}

- (void)handleReceivedTextWithCallback:(NSString *)guid {
	@try {
		if (_setTexts) _setTexts(guid);
	} @catch (NSException *e) {
		SMSAppLog(@"event=callback_exception callback=setTexts name=%@ reason=\"%@\"", e.name, e.reason);
	}
}

- (void)handlePartyTypingWithCallback:(NSDictionary *)vals {
	@try {
		if (_setTyping) _setTyping(vals);
	} @catch (NSException *e) {
		SMSAppLog(@"event=callback_exception callback=setTyping name=%@ reason=\"%@\"", e.name, e.reason);
	}
}

- (void)handleSentTapbackWithCallback:(NSDictionary *)vals {
	@try {
		NSString *guid = [vals[@"guid"] isKindOfClass:[NSString class]] ? vals[@"guid"] : nil;
		if (_sentTapback && guid) _sentTapback([vals[@"tapback"] intValue], guid);
	} @catch (NSException *e) {
		SMSAppLog(@"event=callback_exception callback=sentTapback name=%@ reason=\"%@\"", e.name, e.reason);
	}
}

- (void)handleTextReadWithCallback:(NSString *)guid {
	@try {
		if (_textRead) _textRead(guid);
	} @catch (NSException *e) {
		SMSAppLog(@"event=callback_exception callback=textRead name=%@ reason=\"%@\"", e.name, e.reason);
	}
}

@end

@implementation IWSSender

- (id)init {
	if ((self = [super init])) {
		SMSAppLog(@"event=sender_initialized path=%@", SMSIPC_SPRINGBOARD_SOCKET);
	}
	return self;
}

- (NSDictionary *)ping {
	id result = SMSCallSpringBoard(@"ping", nil, SMSPingTimeout);
	if (![result isKindOfClass:[NSDictionary class]]) {
		SMSAppLog(@"event=springboard_ping reachable=0");
		return nil;
	}
	SMSAppLog(@"event=springboard_ping reachable=1 version=%@ connected=%@ capabilities=%@", result[@"version"], result[@"connected"], result[@"capabilities"]);
	return result;
}

- (BOOL)sendIPCText:(NSString *)body withSubject:(NSString *)subject toAddress:(NSString *)address withAttachments:(NSArray *)paths {
	return [self sendTextReturningFailure:body withSubject:subject toAddress:address withAttachments:paths] == nil;
}

- (NSString *)sendTextReturningFailure:(NSString *)body withSubject:(NSString *)subject toAddress:(NSString *)address withAttachments:(NSArray *)paths {
	NSDictionary *result = [self sendText:body subject:subject toAddress:address from:nil attachments:paths];
	return [result[@"ok"] boolValue] ? nil : result[@"reason"];
}

- (NSDictionary *)sendText:(NSString *)body subject:(NSString *)subject toAddress:(NSString *)address from:(NSString *)from attachments:(NSArray *)paths {
	return [self sendText:body subject:subject toAddress:address from:from service:nil attachments:paths];
}

- (NSDictionary *)sendText:(NSString *)body subject:(NSString *)subject toAddress:(NSString *)address from:(NSString *)from service:(NSString *)service attachments:(NSArray *)paths {
	NSMutableArray *files = [NSMutableArray array];
	for (id path in paths ?: @[]) {
		if ([path isKindOfClass:[NSString class]]) [files addObject:path];
	}
	NSMutableDictionary *args = [NSMutableDictionary dictionaryWithDictionary:@{@"body": body ?: @"", @"subject": subject ?: @"", @"address": address ?: @"", @"attachment": files}];
	if (from.length) args[@"from"] = from;
	if (service.length) args[@"service"] = service;
	id result = SMSCallSpringBoard(@"sendText", args, SMSSendTimeout);
	BOOL ok = SMSBoolResult(result);
	NSMutableDictionary *outcome = [NSMutableDictionary dictionaryWithObject:@(ok) forKey:@"ok"];
	if ([result isKindOfClass:[NSDictionary class]]) {
		for (NSString *key in @[@"reason", @"service", @"from"]) {
			if ([result[key] isKindOfClass:[NSString class]]) outcome[key] = result[key];
		}
	}
	if (!result) outcome[@"reason"] = @"springboard_unreachable";
	if (!ok && !outcome[@"reason"]) outcome[@"reason"] = @"unknown";
	SMSAppLog(@"event=send_text ok=%d reason=%@ service=%@ from_requested=%d from_reported=%d body_length=%lu attachments=%lu", ok, outcome[@"reason"] ?: @"none", outcome[@"service"] ?: @"?", from.length > 0, outcome[@"from"] != nil, (unsigned long)body.length, (unsigned long)files.count);
	return outcome;
}

- (NSDictionary *)getIMessageStatus:(NSArray *)addresses {
	id result = SMSCallSpringBoard(@"getIMessageStatus", @{@"addresses": addresses ?: @[]}, SMSIDStatusTimeout);
	if (![result isKindOfClass:[NSDictionary class]]) {
		SMSAppLog(@"event=imessage_status ok=0 reachable=0 count=%lu", (unsigned long)addresses.count);
		return nil;
	}
	SMSAppLog(@"event=imessage_status ok=%d reason=%@ count=%lu timed_out=%@ elapsed_ms=%@", [result[@"ok"] boolValue], result[@"reason"] ?: @"none", (unsigned long)addresses.count, result[@"timed_out"], result[@"elapsed_ms"]);
	return result;
}

- (NSArray *)getSenders {
	id result = SMSCallSpringBoard(@"getSenders", nil, SMSDefaultTimeout);
	if (![result isKindOfClass:[NSDictionary class]] || ![result[@"ok"] boolValue] || ![result[@"items"] isKindOfClass:[NSArray class]]) {
		SMSAppLog(@"event=senders ok=0 reachable=%d reason=%@", result != nil, [result isKindOfClass:[NSDictionary class]] ? result[@"reason"] : @"unreachable");
		return nil;
	}
	NSMutableArray *items = [NSMutableArray array];
	for (id item in result[@"items"]) {
		if (![item isKindOfClass:[NSDictionary class]] || ![item[@"address"] isKindOfClass:[NSString class]]) continue;
		NSArray *services = [item[@"services"] isKindOfClass:[NSArray class]] ? item[@"services"] : @[];
		NSString *type = [item[@"type"] isKindOfClass:[NSString class]] ? item[@"type"] : @"phone";
		[items addObject:@{@"address": item[@"address"], @"type": type, @"services": services}];
	}
	SMSAppLog(@"event=senders ok=1 count=%lu", (unsigned long)items.count);
	return items;
}

- (BOOL)markConvoAsRead:(NSString *)chat_id {
	NSArray *chats = [chat_id ?: @"" componentsSeparatedByString:@","];
	BOOL all = chats.count > 0;
	for (NSString *chat in chats) {
		if (!chat.length) continue;
		if (!SMSBoolResult(SMSCallSpringBoard(@"setAllAsRead", chat, SMSDefaultTimeout))) all = NO;
	}
	SMSAppLog(@"event=mark_read ok=%d chats=%lu", all, (unsigned long)chats.count);
	return all;
}

- (BOOL)sendTapback:(NSNumber *)tapback forGuid:(NSString *)guid inChat:(NSString *)chat {
	if (!tapback || !guid.length || !chat.length) return NO;
	NSDictionary *args = @{@"tapback": tapback, @"guid": guid, @"chat": chat};
	BOOL ok = SMSBoolResult(SMSCallSpringBoard(@"sendTapback", args, SMSDefaultTimeout));
	SMSAppLog(@"event=send_tapback ok=%d tapback=%@", ok, tapback);
	return ok;
}

- (void)sendTyping:(BOOL)isTyping forChat:(NSString *)chat {
	if (!chat.length) return;
	NSDictionary *args = @{@"chat": chat, @"typing": @(isTyping)};
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		BOOL ok = SMSBoolResult(SMSCallSpringBoard(@"sendTyping", args, SMSTypingTimeout));
		SMSAppLog(@"event=send_typing ok=%d typing=%d", ok, isTyping);
	});
}

- (BOOL)removeObject:(NSString *)chat text:(NSString *)text {
	if (!chat.length) return NO;
	NSMutableDictionary *args = [NSMutableDictionary dictionaryWithObject:chat forKey:@"chat"];
	if (text.length) args[@"text"] = text;
	BOOL ok = SMSBoolResult(SMSCallSpringBoard(@"delete", args, SMSDefaultTimeout));
	SMSAppLog(@"event=delete ok=%d item=%d", ok, text.length > 0);
	return ok;
}

- (NSArray *)getPinnedChats {
	id result = SMSCallSpringBoard(@"getPinnedChats", nil, SMSDefaultTimeout);
	if (![result isKindOfClass:[NSArray class]]) return nil;
	NSMutableArray *chats = [NSMutableArray array];
	for (id chat in result) {
		if ([chat isKindOfClass:[NSString class]]) [chats addObject:chat];
	}
	SMSAppLog(@"event=pinned_chats count=%lu", (unsigned long)chats.count);
	return chats;
}

@end
