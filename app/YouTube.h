#import <UIKit/UIKit.h>

NSURL *CentralYouTubeEmbedURL(NSURL *link);
UIViewController *CentralYouTubeSearch(NSURLSession *session, void (^selection)(NSURL *embedURL));
