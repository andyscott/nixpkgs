{ system ? builtins.currentSystem }:
with import ../lib/testing.nix { inherit system; };
with pkgs.lib;
let
  initMachine = ''
    startAll
    $machine->waitForUnit("rspamd.service");
    $machine->succeed("id \"rspamd\" >/dev/null");
  '';
  checkSocket = socket: user: group: mode: ''
    $machine->succeed("ls ${socket} >/dev/null");
    $machine->succeed("[[ \"\$(stat -c %U ${socket})\" == \"${user}\" ]]");
    $machine->succeed("[[ \"\$(stat -c %G ${socket})\" == \"${group}\" ]]");
    $machine->succeed("[[ \"\$(stat -c %a ${socket})\" == \"${mode}\" ]]");
  '';
  simple = name: enableIPv6: makeTest {
    name = "rspamd-${name}";
    machine = {
      services.rspamd.enable = true;
      networking.enableIPv6 = enableIPv6;
    };
    testScript = ''
      startAll
      $machine->waitForUnit("multi-user.target");
      $machine->waitForOpenPort(11334);
      $machine->waitForUnit("rspamd.service");
      $machine->succeed("id \"rspamd\" >/dev/null");
      ${checkSocket "/run/rspamd/rspamd.sock" "rspamd" "rspamd" "660" }
      sleep 10;
      $machine->log($machine->succeed("cat /etc/rspamd/rspamd.conf"));
      $machine->log($machine->succeed("systemctl cat rspamd.service"));
      $machine->log($machine->succeed("curl http://localhost:11334/auth"));
      $machine->log($machine->succeed("curl http://127.0.0.1:11334/auth"));
      ${optionalString enableIPv6 ''
        $machine->log($machine->succeed("curl http://[::1]:11334/auth"));
      ''}
    '';
  };
in
{
  simple = simple "simple" true;
  ipv4only = simple "ipv4only" false;
  deprecated = makeTest {
    name = "rspamd-deprecated";
    machine = {
      services.rspamd = {
        enable = true;
        bindSocket = [ "/run/rspamd.sock mode=0600 user=root group=root" ];
        bindUISocket = [ "/run/rspamd-worker.sock mode=0666 user=root group=root" ];
      };
    };

    testScript = ''
      ${initMachine}
      $machine->waitForFile("/run/rspamd.sock");
      ${checkSocket "/run/rspamd.sock" "root" "root" "600" }
      ${checkSocket "/run/rspamd-worker.sock" "root" "root" "666" }
      $machine->log($machine->succeed("cat /etc/rspamd/rspamd.conf"));
      $machine->log($machine->succeed("rspamc -h /run/rspamd-worker.sock stat"));
      $machine->log($machine->succeed("curl --unix-socket /run/rspamd-worker.sock http://localhost/ping"));
    '';
  };

  bindports = makeTest {
    name = "rspamd-bindports";
    machine = {
      services.rspamd = {
        enable = true;
        workers.normal.bindSockets = [{
          socket = "/run/rspamd.sock";
          mode = "0600";
          owner = "root";
          group = "root";
        }];
        workers.controller.bindSockets = [{
          socket = "/run/rspamd-worker.sock";
          mode = "0666";
          owner = "root";
          group = "root";
        }];
      };
    };

    testScript = ''
      ${initMachine}
      $machine->waitForFile("/run/rspamd.sock");
      ${checkSocket "/run/rspamd.sock" "root" "root" "600" }
      ${checkSocket "/run/rspamd-worker.sock" "root" "root" "666" }
      $machine->log($machine->succeed("cat /etc/rspamd/rspamd.conf"));
      $machine->log($machine->succeed("rspamc -h /run/rspamd-worker.sock stat"));
      $machine->log($machine->succeed("curl --unix-socket /run/rspamd-worker.sock http://localhost/ping"));
    '';
  };
  customLuaRules = makeTest {
    name = "rspamd-custom-lua-rules";
    machine = {
      environment.etc."tests/no-muh.eml".text = ''
        From: Sheep1<bah@example.com>
        To: Sheep2<mah@example.com>
        Subject: Evil cows

        I find cows to be evil don't you?
      '';
      environment.etc."tests/muh.eml".text = ''
        From: Cow<cow@example.com>
        To: Sheep2<mah@example.com>
        Subject: Evil cows

        Cows are majestic creatures don't Muh agree?
      '';
      services.rspamd = {
        enable = true;
        locals."groups.conf".text = ''
          group "cows" {
            symbol {
              NO_MUH = {
                weight = 1.0;
                description = "Mails should not muh";
              }
            }
          }
        '';
        localLuaRules = pkgs.writeText "rspamd.local.lua" ''
          local rspamd_logger = require "rspamd_logger"
          rspamd_config.NO_MUH = {
            callback = function (task)
              local parts = task:get_text_parts()
              if parts then
                for _,part in ipairs(parts) do
                  local content = tostring(part:get_content())
                  rspamd_logger.infox(rspamd_config, 'Found content %s', content)
                  local found = string.find(content, "Muh");
                  rspamd_logger.infox(rspamd_config, 'Found muh %s', tostring(found))
                  if found then
                    return true
                  end
                end
              end
              return false
            end,
            score = 5.0,
	          description = 'Allow no cows',
            group = "cows",
          }
          rspamd_logger.infox(rspamd_config, 'Work dammit!!!')
        '';
      };
    };
    testScript = ''
      ${initMachine}
      $machine->waitForOpenPort(11334);
      $machine->log($machine->succeed("cat /etc/rspamd/rspamd.conf"));
      $machine->log($machine->succeed("cat /etc/rspamd/rspamd.local.lua"));
      $machine->log($machine->succeed("cat /etc/rspamd/local.d/groups.conf"));
      ${checkSocket "/run/rspamd/rspamd.sock" "rspamd" "rspamd" "660" }
      $machine->log($machine->succeed("curl --unix-socket /run/rspamd/rspamd.sock http://localhost/ping"));
      $machine->log($machine->succeed("rspamc -h 127.0.0.1:11334 stat"));
      $machine->log($machine->succeed("cat /etc/tests/no-muh.eml | rspamc -h 127.0.0.1:11334"));
      $machine->log($machine->succeed("cat /etc/tests/muh.eml | rspamc -h 127.0.0.1:11334 symbols"));
      $machine->waitUntilSucceeds("journalctl -u rspamd | grep -i muh >&2");
      $machine->log($machine->fail("cat /etc/tests/no-muh.eml | rspamc -h 127.0.0.1:11334 symbols | grep NO_MUH"));
      $machine->log($machine->succeed("cat /etc/tests/muh.eml | rspamc -h 127.0.0.1:11334 symbols | grep NO_MUH"));
    '';
  };
}
