#include "SPI.h"

void CPKAttemptQueryingCPSearchManager(NSString *query, void (^completionHandler)(NSArray/* <CPKCharacterEntity *> */ *results)) {
    // this isn't exported from CharacterPicker.framework, and it's easier to do the runtime introspection from ObjC
    Class CPSearchManager = NSClassFromString(@"CPSearchManager");
    id sharedManager = [CPSearchManager sharedSearchManager];

    [sharedManager searchForStickersEmojiAndCharactersWithSearchString:query maxCount:@100 withCompletionHandler: ^(NSArray *results) {
        NSLog(@"CPSearchManager: (%lu results) %@", [results count], results);
        [results enumerateObjectsUsingBlock: ^(id object, NSUInteger index, BOOL *stop) {
            id<CPKCharacterEntity> ent = object;
            NSLog(@"  %lu - %@, %@", index, [ent identifier], [ent imageURL]);
        }];
        completionHandler(results);
    }];
}
