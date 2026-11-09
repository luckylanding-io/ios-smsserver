#ifndef Obj_h
#define Obj_h

#import <Foundation/Foundation.h>

@interface IPCTextWatcher : NSObject

@property (copy) void(^setTexts)(NSString *);
@property (copy) void(^setTyping)(NSDictionary *);
@property (copy) void(^sentTapback)(int, NSString *);
@property (copy) void(^textRead)(NSString *);
+ (instancetype)sharedInstance;
- (instancetype)init;
- (BOOL)isListening;
- (void)handleReceivedTextWithCallback:(NSString *)chat_id;
- (void)handlePartyTypingWithCallback:(NSDictionary *)vals;
- (void)handleSentTapbackWithCallback:(NSDictionary *)vals;
- (void)handleTextReadWithCallback:(NSString *)guid;

@end

@interface IWSSender : NSObject

- (id)init;
- (NSDictionary *)ping;
- (BOOL)sendIPCText:(NSString *)body withSubject:(NSString *)subject toAddress:(NSString *)address withAttachments:(NSArray *)paths;
- (NSString *)sendTextReturningFailure:(NSString *)body withSubject:(NSString *)subject toAddress:(NSString *)address withAttachments:(NSArray *)paths;
- (NSDictionary *)sendText:(NSString *)body subject:(NSString *)subject toAddress:(NSString *)address from:(NSString *)from attachments:(NSArray *)paths;
- (NSDictionary *)sendText:(NSString *)body subject:(NSString *)subject toAddress:(NSString *)address from:(NSString *)from service:(NSString *)service attachments:(NSArray *)paths;
- (NSArray *)getSenders;
- (NSDictionary *)getIMessageStatus:(NSArray *)addresses;
- (BOOL)markConvoAsRead:(NSString *)chat_id;
- (BOOL)sendTapback:(NSNumber *)tapback forGuid:(NSString *)guid inChat:(NSString *)chat;
- (void)sendTyping:(BOOL)isTyping forChat:(NSString *)chat;
- (BOOL)removeObject:(NSString *)chat text:(NSString *)text;
- (NSArray *)getPinnedChats;

@end

#endif
