# defaults

```sh
ls -lah ~/Library/Preferences/com.apple.messages*
ls -lah ~/Library/Preferences/com.apple.MobileSMS*
```

## com.apple.MobileSMS
## com.apple.MobileSMSPreview

## com.apple.MobileSMS.CKDNDList
See `src/DNDState.ts`.

## com.apple.messages.nicknames
## com.apple.messages.pinning

```sh
$ defaults read com.apple.messages.pinning # cat ~/Library/Preferences/com.apple.messages.pinning.plist | plutil -p -
{
    "IMPinningPinConfigMigrationKey-v2-r2" = 1;                 # !unknown!
    IMPinningShouldTryFetchAgainIfNullKey = 1;                  # !unknown!
    pD = {
        pP = (
            "hi@kishan.info",
            "+919401530303",
            "609A00B1-6599-4247-805F-BC491960CE50",             # imessage group, chat.original_group_id
            "458F3072-B516-42E6-921F-A8E10BE7BC38",             # imessage group, chat.original_group_id
            "5383D528D38A36F92E3D4F891BB7CBE505D5FCCB"          # sms group, chat.original_group_id
        );
        pR = 2;                                                 # !unknown!
        pT = "2022-08-08 09:47:33 +0000";                       # last changed timestamp
        pU = dragAndDrop;                                       # or swipeAction or contextMenu
        pV = 2;                                                 # !unknown!
        pZ = {                                                  # all pinned groups
            "458F3072-B516-42E6-921F-A8E10BE7BC38" = {          # imessage group, chat.original_group_id
                h = 7B21621FD2CF1948AC723B3A83BC799D33ABD1CA;
                o = "458F3072-B516-42E6-921F-A8E10BE7BC38";
            };
            5383D528D38A36F92E3D4F891BB7CBE505D5FCCB = {        # sms group, chat.original_group_id
                h = 5383D528D38A36F92E3D4F891BB7CBE505D5FCCB;
                o = 5383D528D38A36F92E3D4F891BB7CBE505D5FCCB;
            };
            "609A00B1-6599-4247-805F-BC491960CE50" = {          # imessage group, chat.original_group_id
                h = C0599FC47CBBD542D43F8CF6CBE08796F7B0CC05;
                o = "609A00B1-6599-4247-805F-BC491960CE50";
            };
        };
    };
}
```
