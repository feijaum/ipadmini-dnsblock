#import <UIKit/UIKit.h>

@interface DrivePhotos : NSObject
@property(nonatomic, readonly) BOOL connected;
@property(nonatomic, readonly) BOOL hasAlbum;
@property(nonatomic, readonly, copy) NSString *endpoint;
@property(nonatomic, readonly, copy) NSString *status;
@property(nonatomic, copy) void (^didUpdate)(void);
- (BOOL)connectToURL:(NSString *)address key:(NSString *)key;
- (void)disconnect;
- (void)resume;
- (void)pause;
- (void)refresh;
- (UIImage *)nextImage;
@end
