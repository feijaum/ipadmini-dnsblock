#import <UIKit/UIKit.h>

@interface LocalWeather : NSObject
- (instancetype)initWithBackdrop:(UIView *)backdrop label:(UILabel *)label;
- (void)resume;
- (void)pause;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
- (void)enable;
- (void)disable;
@end
