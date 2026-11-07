#import <UIKit/UIKit.h>

@interface HouseMusic : NSObject
@property(nonatomic, readonly, copy) NSString *summary;
@property(nonatomic, readonly) BOOL canToggle;
@property(nonatomic, readonly) BOOL canStop;
@property(nonatomic, readonly, getter=isPlaying) BOOL playing;
@property(nonatomic, copy) void (^didUpdate)(void);
- (UIViewController *)searchController;
- (UIViewController *)youtubeControllerWithSelection:(void (^)(NSURL *, NSString *))selection;
- (void)playYouTube:(NSURL *)url title:(NSString *)title;
- (void)stopPlayback;
- (void)togglePlayback;
@end
