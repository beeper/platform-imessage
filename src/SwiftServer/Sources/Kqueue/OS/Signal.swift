// MARK: - Signal

/// The list of supported signals.
public enum Signal {
  case hup
  case int
  case quit
  case ill
  case trap
  case abrt
  case fpe
  case kill
  case bus
  case segv
  case sys
  case pipe
  case alrm
  case term
  case urg
  case stop
  case tstp
  case cont
  case chld
  case ttin
  case ttou
  case io
  case xcpu
  case xfsz
  case vtalrm
  case prof
  case winch
  case usr1
  case usr2

  /// The value of the signal enum for the current platform.
  public var value: Int32 {
    guard let v = Signal.toValues[self] else {
      fatalError("unknown Signal enum: \(self)")
    }
    return v
  }

  static func make(_ value: Int32) -> Signal? {
    return fromValues[value]
  }

  private static let toValues: [Signal: Int32] = [
    .hup: SIGHUP,
    .int: SIGINT,
    .quit: SIGQUIT,
    .ill: SIGILL,
    .trap: SIGTRAP,
    .abrt: SIGABRT,
    .fpe: SIGFPE,
    .kill: SIGKILL,
    .bus: SIGBUS,
    .segv: SIGSEGV,
    .sys: SIGSYS,
    .pipe: SIGPIPE,
    .alrm: SIGALRM,
    .term: SIGTERM,
    .urg: SIGURG,
    .stop: SIGSTOP,
    .tstp: SIGTSTP,
    .cont: SIGCONT,
    .chld: SIGCHLD,
    .ttin: SIGTTIN,
    .ttou: SIGTTOU,
    .io: SIGIO,
    .xcpu: SIGXCPU,
    .xfsz: SIGXFSZ,
    .vtalrm: SIGVTALRM,
    .prof: SIGPROF,
    .winch: SIGWINCH,
    .usr1: SIGUSR1,
    .usr2: SIGUSR2,
  ]

  private static let fromValues: [Int32: Signal] = [
    SIGHUP: .hup,
    SIGINT: .int,
    SIGQUIT: .quit,
    SIGILL: .ill,
    SIGTRAP: .trap,
    SIGABRT: .abrt,
    SIGFPE: .fpe,
    SIGKILL: .kill,
    SIGBUS: .bus,
    SIGSEGV: .segv,
    SIGSYS: .sys,
    SIGPIPE: .pipe,
    SIGALRM: .alrm,
    SIGTERM: .term,
    SIGURG: .urg,
    SIGSTOP: .stop,
    SIGTSTP: .tstp,
    SIGCONT: .cont,
    SIGCHLD: .chld,
    SIGTTIN: .ttin,
    SIGTTOU: .ttou,
    SIGIO: .io,
    SIGXCPU: .xcpu,
    SIGXFSZ: .xfsz,
    SIGVTALRM: .vtalrm,
    SIGPROF: .prof,
    SIGWINCH: .winch,
    SIGUSR1: .usr1,
    SIGUSR2: .usr2,
  ]
}
