import Darwin

enum Terminal {
    static var size: (width: Int, height: Int)? {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 else { return nil }
        return (width: Int(size.ws_col), height: Int(size.ws_row))
    }
}
