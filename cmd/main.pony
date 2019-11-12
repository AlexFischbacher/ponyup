use "cli"
use "files"
use "term"

actor Main is PonyupNotify
  let _env: Env
  let _default_prefix: String
  var _verbose: Bool = false
  var _boring: Bool = false

  new create(env: Env) =>
    _env = consume env

    var home = ""
    for v in _env.vars.values() do
      if v.substring(0, 5) == "HOME=" then
        home = v.substring(5)
        break
      end
    end
    _default_prefix = home + "/.pony"

    if not Platform.posix() then
      _env.exitcode(1)
      _env.out.print("error: Unsupported platform")
      return
    end

    let auth =
      try
        _env.root as AmbientAuth
      else
        _env.exitcode(1)
        _env.out.print("error: environment does not have ambient authority")
        return
      end

    run_command(auth)

  be run_command(auth: AmbientAuth) =>
    let command =
      match recover val CLI.parse(_env.args, _env.vars, _default_prefix) end
      | let c: Command val => c
      | (let exit_code: U8, let msg: String) =>
        if exit_code == 0 then
          _env.out.print(msg)
        else
          log(Err, msg + "\n")
          _env.out.print(CLI.help(_default_prefix))
          _env.exitcode(exit_code.i32())
        end
        return
      end

    _verbose = command.option("verbose").bool()
    _boring = command.option("boring").bool()

    var prefix = command.option("prefix").string()
    if prefix == "" then prefix = _default_prefix end
    log(Extra, "prefix: " + prefix)

    let ponyup_dir =
      try
        FilePath(auth, prefix + "/ponyup")?
      else
        log(Err, "invalid ponyup prefix: " + prefix)
        return
      end

    if (not ponyup_dir.exists()) and (not ponyup_dir.mkdir()) then
      log(Err, "unable to create root directory: " + ponyup_dir.path)
    end

    let lockfile =
      try
        recover CreateFile(ponyup_dir.join(".lock")?) as File end
      else
        log(Err, "unable to create lockfile (" + ponyup_dir.path + "/.lock)")
        return
      end

    let ponyup = Ponyup(_env, auth, ponyup_dir, consume lockfile, this)

    match command.fullname()
    | "ponyup/version" => _env.out .> write("ponyup ") .> print(Version())
    | "ponyup/show" => show(ponyup, command)
    | "ponyup/update" => sync(ponyup, command)
    else
      log(InternalErr, "Unknown command: " + command.fullname())
    end

  be show(ponyup: Ponyup, command: Command val) =>
    // TODO
    None

    // let ponyup_dir =
    //   try
    //     _ponyup_dir(auth, prefix)?
    //   else
    //     log(Err, "invalid path: " + prefix)
    //     return
    //   end

    // let package = command.option("package").string()

    // ponyup_dir.walk(
    //   {(path, entries) =>
    //     try
    //       if path.path.substring(-3) == "bin" then
    //         let version_start = path.path.rfind("/", -5)? + 1
    //         let version = recover val path.path.substring(version_start, -4) end
    //         for name in entries.values() do
    //           if (name == package) or (package == "") then
    //             log.print("\t".join([name; version].values()))
    //           end
    //         end
    //       end

    //       var i: USize = 0
    //       while i < entries.size() do
    //         let a = path.path == (prefix + "/ponyup")
    //         let b = entries(i)? == "bin"
    //         if not (a xor b) then
    //           entries.delete(i)?
    //           i = i - 1
    //         end
    //         i = i + 1
    //       end
    //     end
    //   })

  be sync(ponyup: Ponyup, command: Command val) =>
    let chan = command.arg("version/channel").string().split("-")
    let pkg =
      try
        Packages.from_fragments(
          command.arg("package").string(),
          chan(0)?,
          try chan(1)? else "latest" end,
          command.option("libc").string())?
      else
        log(Err, "".join(
          [ "unexpected selection: "
            command.arg("package").string()
            "-"; command.arg("version/channel").string()
          ].values()))
        return
      end
    ponyup.sync(pkg)

  be log(level: LogLevel, msg: String) =>
    let colorful =
      {(ansi_color_code: String, msg: String): String iso^ =>
        "".join(
          [ if not _boring then ansi_color_code else "" end
            msg
            if not _boring then ANSI.reset() else "" end
          ].values())
      }

    match level
    | Info | Extra =>
      if (level is Info) or _verbose then
        if level is Extra then
          _env.out.write(colorful(ANSI.grey(), "info: "))
        end
        _env.out.print(msg)
      end
    | Err | InternalErr =>
      _env.exitcode(1)
      var msg' =
        // strip error prefix from CLI package
        if msg.substring(0, 7) == "Error: " then
          msg.substring(7)
        else
          consume msg
        end
      _env.out .> write(colorful(ANSI.bright_red(), "error: ")) .> print(msg')

      if level is InternalErr then
        _env.out
          .> write("Internal error encountered. Please open an issue at ")
          .> print("https://github.com/ponylang/ponyup")
      end
    end

  be write(str: String) =>
    _env.out.write(str)

primitive Info
primitive Extra
primitive Err
primitive InternalErr
type LogLevel is (InternalErr | Err | Info | Extra)
