#import <UIKit/UIKit.h>

@interface HouseMusic : NSObject
@property(nonatomic, readonly, copy) NSString *summary;
@property(nonatomic, readonly, copy) NSString *currentVideo;
@property(nonatomic, readonly, copy) NSArray *queuedTracks;
@property(nonatomic, readonly) NSUInteger thumbnailRevision;
@property(nonatomic, readonly) NSTimeInterval elapsed;
@property(nonatomic, readonly) NSTimeInterval duration;
@property(nonatomic, readonly) BOOL canToggle;
@property(nonatomic, readonly) BOOL canStop;
@property(nonatomic, readonly, getter=isPlaying) BOOL playing;
@property(nonatomic, copy) void (^didUpdate)(void);
- (UIViewController *)youtubeControllerWithSelection:(void (^)(NSURL *, NSString *))selection;
- (void)playYouTube:(NSURL *)url title:(NSString *)title;
- (NSString *)titleForVideo:(NSString *)video;
- (void)loadTitlesForVideos:(NSArray *)videos;
- (UIImage *)thumbnailForVideo:(NSString *)video;
- (void)seekToSecond:(NSTimeInterval)second;
- (void)skipTrack;
- (void)stopPlayback;
- (void)togglePlayback;
@end
