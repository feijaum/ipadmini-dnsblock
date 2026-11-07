#import <UIKit/UIKit.h>

NSURL *CentralYouTubeWatchURL(NSURL *link);
NSURLRequest *CentralYouTubeAudioRequest(NSString *route, NSString *identifier);
UIViewController *CentralYouTubeSearch(NSURLSession *session, void (^selection)(NSURL *url, NSString *title));
