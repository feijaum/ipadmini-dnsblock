#import <UIKit/UIKit.h>

@interface HouseMusic : NSObject
@property(nonatomic, readonly, copy) NSString *summary;
@property(nonatomic, readonly) BOOL canToggle;
@property(nonatomic, readonly, getter=isPlaying) BOOL playing;
@property(nonatomic, copy) void (^didUpdate)(void);
- (UIViewController *)searchController;
- (void)togglePlayback;
- (void)pause;
@end
