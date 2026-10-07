#!/usr/bin/env python3
"""Game day: something in the local stack gets broken and you are not told what.

    python scripts/gameday.py start        break something at random, show only the symptom
    python scripts/gameday.py start --level=2      only the easier scenarios (1-4)
    python scripts/gameday.py start --id=<id>      replay one you have played (ids are in `history`)
    python scripts/gameday.py hint         next hint (there are three; each one costs you)
    python scripts/gameday.py reveal       what it was, how a senior would have found it; restores the stack
    python scripts/gameday.py abort        restore the stack without revealing the answer
    python scripts/gameday.py status       is a game running, for how long, hints used
    python scripts/gameday.py history      what you have played and how it went

The point is practice at DIAGNOSIS, which reading a runbook does not give you. You
get the symptom the way it would really arrive - a ticket, a page, sometimes
nothing at all - and you find the cause with logs, metrics and docker, not by
reading this file or docker-compose.yml to see what changed.

Rules that make it worth doing:
  1. Before you touch anything, write down your first hypothesis and what you
     expect to see if it is true.
  2. Say each next step out loud, with the reason for it.
  3. No peeking at the scenario file. It is stored encoded for that reason.
  4. When you think you have it, write the root cause in one sentence BEFORE
     running `reveal`. Then compare.

Requires the stack to be running locally (`docker compose up -d`). Every scenario
is reversible, and `reveal` or `abort` puts things back.

Standard library only.
"""
import base64
import json
import os
import random
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
STATE_DIR = os.path.join(ROOT, ".gameday")
STATE = os.path.join(STATE_DIR, "state.json")
HISTORY = os.path.join(STATE_DIR, "history.jsonl")
OVERRIDE = os.path.join(STATE_DIR, "override.yml")
SCENARIOS = os.path.join(os.path.dirname(__file__), "gameday_scenarios.dat")

try:                                    # Windows consoles default to a legacy code page
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def load_scenarios():
    with open(SCENARIOS, "rb") as f:
        return json.loads(base64.b64decode(f.read()).decode("utf-8"))


def run(argv, check=False):
    """Run a command from the repo root. Output is kept out of sight on purpose."""
    proc = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(os.path.join(STATE_DIR, "commands.log"), "a", encoding="utf-8") as log:
        log.write("%s rc=%s\n%s%s\n" % (time.strftime("%H:%M:%S"), proc.returncode, proc.stdout[-400:], proc.stderr[-400:]))
    if check and proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip()[-300:] or "command failed")
    return proc


def network_name():
    out = run(["docker", "inspect", "-f", "{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}", "prometheus"])
    names = out.stdout.split()
    return names[0] if names else "observeops_observeops"


def expand(argv, net):
    return [a.replace("{NET}", net).replace("{OVERRIDE}", OVERRIDE) for a in argv]


def read_state():
    if not os.path.exists(STATE):
        return None
    with open(STATE, encoding="utf-8") as f:
        return json.load(f)


def write_state(state):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(STATE, "w", encoding="utf-8") as f:
        json.dump(state, f)


def current(state, scenarios):
    sid = base64.b64decode(state["sid"]).decode("utf-8")
    return next(s for s in scenarios if s["id"] == sid)


def played_ids():
    if not os.path.exists(HISTORY):
        return []
    with open(HISTORY, encoding="utf-8") as f:
        return [json.loads(line)["id"] for line in f if line.strip()]


def fmt_elapsed(seconds):
    return "%d min %02d s" % (seconds // 60, seconds % 60)


def restore(scenario):
    net = network_name()
    for argv in scenario["restore"]:
        run(expand(argv, net))
    if os.path.exists(OVERRIDE):
        os.remove(OVERRIDE)


def cmd_start(args):
    if read_state():
        print("A game is already running. Finish it with `reveal`, or `abort` to restore without the answer.")
        return 1
    running = run(["docker", "compose", "ps", "-q"]).stdout.split()
    if len(running) < 10:
        print("The stack does not look like it is running (%d containers). Start it first:" % len(running))
        print("    docker compose up -d      # then wait a minute for health checks")
        return 1

    scenarios = load_scenarios()
    level = None
    for a in args:
        if a.startswith("--level="):
            level = int(a.split("=", 1)[1])
    pool = [s for s in scenarios if level is None or s["difficulty"] <= level]
    done = played_ids()
    fresh = [s for s in pool if s["id"] not in done]
    scenario = random.choice(fresh or pool)      # everything you have not seen comes first
    for a in args:                               # replay one you have already played
        if a.startswith("--id="):
            wanted = [s for s in scenarios if s["id"] == a.split("=", 1)[1]]
            if not wanted:
                print("No scenario with that id. `history` lists the ones you have played.")
                return 1
            scenario = wanted[0]

    net = network_name()
    if scenario.get("override"):
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(OVERRIDE, "w", encoding="utf-8") as f:       # JSON is valid YAML
            json.dump({"services": scenario["override"]}, f)
    try:
        for argv in scenario["inject"]:
            run(expand(argv, net), check=True)
    except RuntimeError as exc:
        print("Could not inject the failure: %s" % exc)
        print("Restoring whatever was changed. Details are in .gameday/commands.log")
        restore(scenario)
        return 1

    write_state({"sid": base64.b64encode(scenario["id"].encode()).decode(), "started": time.time(), "hints": 0})
    print("")
    print("=" * 74)
    print("  GAME DAY  -  something is broken. This is all you know:")
    print("=" * 74)
    print("")
    print("  " + scenario["page"])
    print("")
    print("  Difficulty %d of 4.  The clock is running." % scenario["difficulty"])
    print("")
    print("  Before you type anything: write your first hypothesis and what you")
    print("  expect to see if it is right. Then go and look.")
    print("")
    print("    stuck?        python scripts/gameday.py hint")
    print("    found it?     write the cause in one sentence, THEN: python scripts/gameday.py reveal")
    print("")
    print("  Useful places: http://localhost:9090/prometheus/   http://localhost:9093   http://localhost:3000/grafana/")
    print("")
    return 0


def cmd_hint(_args):
    state = read_state()
    if not state:
        print("No game is running. Start one with: python scripts/gameday.py start")
        return 1
    scenario = current(state, load_scenarios())
    n = state["hints"]
    if n >= len(scenario["hints"]):
        print("That was the last hint. If you are still stuck, `reveal` and study the path.")
        return 0
    print("")
    print("  Hint %d of %d:" % (n + 1, len(scenario["hints"])))
    print("  " + scenario["hints"][n])
    print("")
    state["hints"] = n + 1
    write_state(state)
    return 0


def cmd_status(_args):
    state = read_state()
    if not state:
        print("No game is running.")
        return 0
    print("A game is running: %s elapsed, %d hint(s) used." % (fmt_elapsed(int(time.time() - state["started"])), state["hints"]))
    return 0


def cmd_reveal(_args):
    state = read_state()
    if not state:
        print("No game is running.")
        return 1
    scenario = current(state, load_scenarios())
    elapsed = int(time.time() - state["started"])
    print("")
    print("=" * 74)
    print("  REVEAL  -  %s, %d hint(s) used" % (fmt_elapsed(elapsed), state["hints"]))
    print("=" * 74)
    print("")
    print("  WHAT WAS BROKEN")
    print("  " + scenario["cause"])
    print("")
    print("  THE PATH A SENIOR TAKES  (the order is the lesson, not the commands)")
    for i, step in enumerate(scenario["path"], 1):
        print("   %2d. %s" % (i, step))
    print("")
    print("  THE CHECK THAT SPLITS THE PROBLEM IN TWO")
    print("  " + scenario["split"])
    print("")
    print("  WHAT YOU WOULD CHANGE SO THIS IS CAUGHT NEXT TIME")
    print("  " + scenario["guardrail"])
    print("")
    print("  HOW TO SAY IT IN AN INTERVIEW")
    print("  " + scenario["interview"])
    print("")
    print("  Restoring the stack...")
    restore(scenario)
    os.remove(STATE)
    with open(HISTORY, "a", encoding="utf-8") as f:
        f.write(json.dumps({"id": scenario["id"], "difficulty": scenario["difficulty"], "seconds": elapsed,
                            "hints": state["hints"], "date": time.strftime("%Y-%m-%d")}) + "\n")
    print("  Restored. Give it a minute before starting another game.")
    print("")
    print("  SCORE YOURSELF HONESTLY, one point each:")
    print("    [ ] I wrote a hypothesis before I ran anything")
    print("    [ ] My second step depended on the result of my first")
    print("    [ ] I found the root cause, not just the symptom")
    print("    [ ] I can say which single check split the problem")
    print("    [ ] I named a guardrail without reading it above")
    print("  Then write the five-line postmortem in your log. 4 or 5 is a pass.")
    print("")
    return 0


def cmd_abort(_args):
    state = read_state()
    if not state:
        print("No game is running.")
        return 0
    restore(current(state, load_scenarios()))
    os.remove(STATE)
    print("Restored. The scenario stays unplayed, so it can come up again.")
    return 0


def cmd_history(_args):
    scenarios = load_scenarios()
    done = played_ids()
    print("%d scenarios in the bank, %d played at least once." % (len(scenarios), len(set(done))))
    if os.path.exists(HISTORY):
        print("")
        print("  date        time      hints  difficulty  scenario")
        with open(HISTORY, encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    h = json.loads(line)
                    print("  %s  %-8s  %-5d  %-10d  %s" % (h["date"], fmt_elapsed(h["seconds"]), h["hints"], h["difficulty"], h["id"]))
        print("")
        print("  Replaying one you have seen still helps: aim to halve the time with no hints.")
    return 0


def cmd_export(args):
    """Write the scenarios as readable JSON (for editing). Reading it spoils the games."""
    path = args[0] if args else os.path.join(STATE_DIR, "scenarios.json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(load_scenarios(), f, indent=2, ensure_ascii=False)
    print("Exported to %s" % path)
    return 0


def cmd_import(args):
    """Re-encode an edited scenarios JSON file."""
    with open(args[0], encoding="utf-8") as f:
        data = json.load(f)
    for s in data:
        for key in ("id", "difficulty", "page", "inject", "restore", "hints", "cause", "path", "split", "guardrail", "interview"):
            assert key in s, "scenario %s is missing %s" % (s.get("id"), key)
    with open(SCENARIOS, "wb") as f:
        f.write(base64.b64encode(json.dumps(data, ensure_ascii=False).encode("utf-8")))
    print("Imported %d scenarios." % len(data))
    return 0


COMMANDS = {"start": cmd_start, "hint": cmd_hint, "reveal": cmd_reveal, "abort": cmd_abort,
            "status": cmd_status, "history": cmd_history, "export": cmd_export, "import": cmd_import}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        return 0 if len(sys.argv) < 2 else 1
    return COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    sys.exit(main())
