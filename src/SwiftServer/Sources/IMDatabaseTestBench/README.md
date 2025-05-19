# IMDatabaseTestBench

Test program for [the `IMDatabase` library](../IMDatabase).

Because Full Disk Access is needed to read Messages data, a command like this
may be used to iterate on the program:

```
xcrun swift build --product IMDatabaseTestBench \
  && codesign -f -vvv --sign "Apple Development: $MY_NAME" --timestamp .build/debug/IMDatabaseTestBench \
  && ./.build/debug/IMDatabaseTestBench
```
