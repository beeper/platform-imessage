#import <Foundation/Foundation.h>
#import <stdio.h>
#import "NSObject+AppleScriptRunner.h"

#define INPUT_LEN 128 * 1024 // 128 KB

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        AppleScriptRunner* runner = [[AppleScriptRunner alloc] init];
        NSString *arg = [NSString stringWithCString: argv[argc-1] encoding:NSUTF8StringEncoding]; // scripts directory
        // load from embedded JSON
        if ([arg isEqual:@"embedded-json"]) {
            [runner loadFromEmbeddedJSON];
        } else {
            NSURL *scriptsDirectory = [[NSURL alloc] initFileURLWithPath:arg isDirectory:YES];
            NSLog(@"Loading from scripts at: %@", [scriptsDirectory path]);

            [runner loadScripts:scriptsDirectory];
            [runner generateJSON];
        }

        NSFileHandle *handle = [NSFileHandle fileHandleWithStandardOutput];

        char word[INPUT_LEN];
        NSDictionary *dict;
        NSData* input;
        NSData* output;
        NSString *script, *tag;
        NSArray *args;

        while (1) {
            scanf(" %[^\n]s", word);

            input = [[NSString stringWithCString:word encoding:NSUTF8StringEncoding] dataUsingEncoding:NSUTF8StringEncoding];
            dict = [NSJSONSerialization JSONObjectWithData:input options:NSJSONReadingAllowFragments error:nil];

            script = [dict objectForKey: @"scriptName"];
            tag = [dict objectForKey: @"tag"];
            args = [dict objectForKey: @"args"];
            if (!tag) tag = @"";
            if (!args) args = [[NSArray alloc] init];

            output = [runner executeScript:script :tag :args];
            [handle writeData:output];
            [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];

            memset(word, 0, INPUT_LEN);
        }
    }
    return 0;
}
