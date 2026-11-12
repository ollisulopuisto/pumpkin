#import <Foundation/Foundation.h>

// Range-checked (1-65535) transformer used by the port bindings in the UI.
@interface NSPortNumberTransformer : NSValueTransformer

// Registers the transformer under PortNumberTransformerName.
+(void)registerForPortBindings;

@end

extern NSString * const PortNumberTransformerName;
