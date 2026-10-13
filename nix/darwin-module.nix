# nix-darwin module: the collector as a launchd user agent.
#
# Accessibility (TCC) is keyed on code identity. The reader is installed as an
# app bundle at a stable path and re-signed at every activation with one stable
# self-signed identity in the System keychain (created once), so a single
# Accessibility grant survives every rebuild. That grant is the one manual step.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.friend-location-collector;
  label = "com.alexmiller.friend-location-collector";
  identity = "friend-location-collector-signing";
  appPath = "/Applications/FriendLocationCollector.app";
  executable = "${appPath}/Contents/MacOS/friend-location-collector";
  home = "/Users/${cfg.user}";
  logDir = "${home}/Library/Logs/friend-location-collector";

  app = pkgs.runCommand "friend-location-collector-app" { } ''
    mkdir -p "$out/Contents/MacOS"
    cp ${cfg.package}/bin/findmy "$out/Contents/MacOS/friend-location-collector"
    cat > "$out/Contents/Info.plist" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>${label}</string>
      <key>CFBundleExecutable</key><string>friend-location-collector</string>
      <key>CFBundleName</key><string>Friend Location Collector</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>LSUIElement</key><true/>
    </dict></plist>
    EOF
  '';
in
{
  options.services.friend-location-collector = {
    enable = lib.mkEnableOption "the Find My collector appending coarse city checks to a soma stream";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      description = "Reader package whose `findmy` becomes the app's executable.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      example = "alice";
      description = "Console user whose Find My window is read.";
    };

    hubUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://soma.example.workers.dev";
      description = "Base URL of the soma hub receiving the stream.";
    };

    tokenCommand = lib.mkOption {
      type = lib.types.str;
      example = "/usr/bin/security find-generic-password -s friend-location-collector -a soma-hub -w";
      description = ''
        Shell command printing a hub token granted exactly
        `streams:append:<stream>`. Runs before each collection in the agent's
        login session; its output is never logged.
      '';
    };

    handles = lib.mkOption {
      type = lib.types.str;
      default = "${home}/.local/state/friend-location-collector/handles.json";
      description = ''
        JSON object mapping each `source_handle_key` to the person id written
        to the stream. Rows whose key is absent are counted, never written.
      '';
    };

    stream = lib.mkOption {
      type = lib.types.str;
      default = "friend_city_checks";
      description = "Stream name the records are appended to.";
    };

    interval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Seconds between collections.";
    };

    repair = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Pass `--repair`: restart Find My when its window is unreadable, or at
        most hourly when every displayed age is over 20 minutes (a long-running
        Find My can stop refreshing friends). The window visibly reappears, so
        this suits an unattended Mac.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    system.activationScripts.postActivation.text = lib.mkAfter ''
      # Stable self-signed signing identity (one-time). Stable certificate =>
      # stable designated requirement => the Accessibility grant persists.
      if ! /usr/bin/security find-certificate -c ${identity} /Library/Keychains/System.keychain >/dev/null 2>&1; then
        echo "creating code-signing identity ${identity} (one-time)..."
        _t="$(/usr/bin/mktemp -d)"
        /usr/bin/printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=%s\n[v3]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' ${identity} > "$_t/req.cnf"
        /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$_t/key.pem" -out "$_t/cert.pem" -config "$_t/req.cnf"
        # one-time transport password for the throwaway p12 (`security`
        # rejects empty-password PKCS12); the key then lives in the keychain
        _p="$(/usr/bin/openssl rand -hex 16)"
        /usr/bin/openssl pkcs12 -export -inkey "$_t/key.pem" -in "$_t/cert.pem" -out "$_t/id.p12" -passout "pass:$_p"
        /usr/bin/security import "$_t/id.p12" -k /Library/Keychains/System.keychain -P "$_p" -T /usr/bin/codesign -A
        /bin/rm -rf "$_t"
      fi

      echo "installing ${appPath}..."
      /bin/rm -rf ${appPath}
      /bin/cp -R ${app} ${appPath}
      /bin/chmod -R u+w ${appPath}
      /usr/bin/codesign --force --identifier ${label} --sign ${identity} ${appPath}
      /usr/bin/install -d -o ${cfg.user} -g staff ${logDir}
      # A KeepAlive loop keeps running the old code until restarted.
      _uid="$(/usr/bin/id -u ${cfg.user})"
      /bin/launchctl kickstart -k "gui/$_uid/${label}" >/dev/null 2>&1 || true
    '';

    launchd.user.agents.friend-location-collector.serviceConfig = {
      Label = label;
      ProgramArguments = [
        executable
        "collect"
        "--hub"
        cfg.hubUrl
        "--token-cmd"
        cfg.tokenCommand
        "--handles"
        cfg.handles
        "--stream"
        cfg.stream
        "--every"
        (toString cfg.interval)
      ] ++ lib.optional cfg.repair "--repair";
      KeepAlive = true;
      RunAtLoad = true;
      ThrottleInterval = 60;
      # The Find My window and the login keychain exist only in the GUI session.
      LimitLoadToSessionType = "Aqua";
      StandardOutPath = "${logDir}/collector.log";
      StandardErrorPath = "${logDir}/collector.log";
    };
  };
}
