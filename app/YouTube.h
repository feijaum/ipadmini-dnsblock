#import <UIKit/UIKit.h>

NSURL *CentralYouTubeWatchURL(NSURL *link);
BOOL CentralYouTubeMediaHost(NSString *host);
NSURLRequest *CentralYouTubePlayerRequest(NSString *video);
NSURL *CentralYouTubeAudioURL(NSData *data);
NSURLRequest *CentralYouTubePlaylistRequest(NSString *playlist);
NSArray *CentralYouTubePlaylistItems(NSData *data);
UIViewController *CentralYouTubeSearch(NSURLSession *session, void (^selection)(NSURL *url, NSString *title));
