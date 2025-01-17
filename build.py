#!/usr/bin/env python
import subprocess
import argparse

def run(project, ghcjs, cmd):
  subprocess.check_call([
    "nix-shell", "build.nix", "-A", project + ".env",
    "--arg", "ghcjs", "true" if ghcjs else "false",
    "--run", "cd " + project + " && runhaskell Setup.hs " + cmd])

def configure(project, ghcjs):
  print("### Configuring project {}, ".format(project) + ("using GHCjs." if ghcjs else "using GHC."))
  run(project, ghcjs, "configure" + (" --ghcjs" if ghcjs else ""))

def build(project, ghcjs):
  print("### Configuring project {}, ".format(project) + ("using GHCjs." if ghcjs else "using GHC."))
  run(project, ghcjs, "build")

def repl(project, ghcjs):
  print("### REPLing project {}, ".format(project) + ("using GHCjs." if ghcjs else "using GHC."))
  run(project, ghcjs, "repl --ghc-options='-fobject-code -O0'")

def build_nix(project, ghcjs):
  print("### Building project {} (nix), ".format(project) + ("using GHCjs." if ghcjs else "using GHC."))
  subprocess.check_call(
    ["nix-build", "build.nix", "-A", project,
      "--arg", "ghcjs", "true" if ghcjs else "false"])

parser = argparse.ArgumentParser()
parser.add_argument("--ghc", help = "Use GHC rather than GHCjs", action = "store_true")
action = parser.add_mutually_exclusive_group()
action.add_argument("--configure", help = "Only configure", action = "store_true")
action.add_argument("--repl", help = "Run repl", action = "store_true")
parser.add_argument("project", metavar = "PROJECT", nargs = "?")
args = parser.parse_args()

if args.project:
  if args.configure:
    configure(args.project, not args.ghc)
  elif args.repl:
    configure(args.project, False)
    repl(args.project, False)
  else:
    configure(args.project, not args.ghc)
    build(args.project, not args.ghc)
else:
  for ghcjs in [True, False]:
    projects = ["anapo", "anapo-test-app", "js-framework-benchmark"]
    for project in projects:
      build_nix(project, ghcjs)
