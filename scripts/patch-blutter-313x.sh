#!/bin/bash
# fler-dart: Dart 3.13.x runtime fixes for blutter (applied on top of patch-dart313.sh)
#
#  Two independent defects that both show up as "Blutter 引擎错误码 code=-2" in the Fler app:
#
#  1. DartLoader.cpp — VM init is not idempotent.
#     Dart_SetVMFlags()/Dart_Initialize() may only run once per process: Dart's
#     Flags::ProcessCommandLineFlags() returns "Flags already set" when flags are already
#     initialized, and blutter calls them from DartLoader::Load() on *every* analysis.
#     The flags are only reset by DartLoader::Unload() -> Dart_Cleanup(), and Unload() lives in
#     ~DartApp() — which is never reached when an analysis aborts through a signal (the app's JNI
#     uses siglongjmp) or throws during DartApp construction. Result: the first failure poisons the
#     whole app process and every later analysis dies in ~4 ms with "Flags already set" (-2),
#     hiding the real error.
#
#  2. DartTypes.cpp — DartTypeDb::FindOrAdd(dart::AbstractTypePtr) aborts on anything that is not
#     Type/RecordType/TypeRef/TypeParameter/FunctionType (FATAL("Invalid abstract type")).
#     Dart 3.13.x snapshots hit that path, which surfaces as SIGABRT (-997) at ~86 ms. Log the
#     offending class id once and fall back to `dynamic` instead of aborting, so analysis continues
#     and the real cause is visible in logcat.
#
# Usage: bash patch-blutter-313x.sh <blutter-src-dir>
#   e.g. bash patch-blutter-313x.sh /tmp/build/blutter/blutter/src
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <blutter-src-dir>"
  exit 1
fi
SRC_DIR="$1"

python3 - "$SRC_DIR" << 'PYEOF'
import os, sys

src = sys.argv[1]

def read(name):
    return open(os.path.join(src, name), encoding='utf-8').read()

def write(name, text):
    with open(os.path.join(src, name), 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)

# ── 1. DartLoader.cpp: idempotent VM init ─────────────────────────────────────
name = 'DartLoader.cpp'
c = read(name)
if 'fler-dart: idempotent VM init' not in c:
    old = "static void init_vm_flags()\n{\n"
    new = ("// fler-dart: idempotent VM init -- Dart_SetVMFlags/Dart_Initialize may only run\n"
           "// once per process (Dart returns \"Flags already set\" otherwise).\n"
           "static bool g_fler_vm_inited = false;\n"
           "\n"
           "static void init_vm_flags()\n"
           "{\n"
           "\tif (g_fler_vm_inited) return;\n")
    assert c.count(old) == 1, 'DartLoader.cpp: init_vm_flags pattern not found'
    c = c.replace(old, new)

    old = ("static void init_dart(const uint8_t* vm_snapshot_data, const uint8_t* vm_snapshot_instructions)\n"
           "{\n"
           "\tchar* error = NULL;\n")
    new = ("static void init_dart(const uint8_t* vm_snapshot_data, const uint8_t* vm_snapshot_instructions)\n"
           "{\n"
           "\tif (g_fler_vm_inited) {\n"
           "\t\t// fler-dart: a previous analysis already initialized the VM and it stays\n"
           "\t\t// initialized until Dart_Cleanup(). Drop an isolate left behind by an\n"
           "\t\t// aborted run, then reuse the VM instead of re-initializing it.\n"
           "\t\tif (Dart_CurrentIsolate() != nullptr) {\n"
           "\t\t\tDart_ShutdownIsolate();\n"
           "\t\t}\n"
           "\t\treturn;\n"
           "\t}\n"
           "\tchar* error = NULL;\n")
    assert c.count(old) == 1, 'DartLoader.cpp: init_dart pattern not found'
    c = c.replace(old, new)

    old = ("\terror = Dart_Initialize(&init_params);\n"
           "\tif (error) {\n"
           "\t\tthrow std::runtime_error(error);\n"
           "\t}\n"
           "}\n")
    new = ("\terror = Dart_Initialize(&init_params);\n"
           "\tif (error) {\n"
           "\t\tthrow std::runtime_error(error);\n"
           "\t}\n"
           "\tg_fler_vm_inited = true;\n"
           "}\n")
    assert c.count(old) == 1, 'DartLoader.cpp: Dart_Initialize tail pattern not found'
    c = c.replace(old, new)

    old = "\tignore_result(Dart_Cleanup());\n}"
    new = ("\tignore_result(Dart_Cleanup());\n"
           "\tg_fler_vm_inited = false; // fler-dart: cleanup resets VM flags, allow re-init\n"
           "}")
    assert c.count(old) == 1, 'DartLoader.cpp: Unload pattern not found'
    c = c.replace(old, new)
    write(name, c)
    print('  DartLoader.cpp: idempotent VM init applied')
else:
    print('  DartLoader.cpp: already patched')

# ── 2. DartTypes.cpp: tolerant abstract-type dispatch ─────────────────────────
name = 'DartTypes.cpp'
c = read(name)
if 'fler-dart: tolerant abstract-type dispatch' not in c:
    if '#include <cstdio>' not in c:
        old_inc = '#include <sstream>\n'
        assert c.count(old_inc) == 1, 'DartTypes.cpp: <sstream> include not found'
        c = c.replace(old_inc, old_inc + '#include <cstdio> // fler-dart: fprintf/stderr diagnostics\n')
    old = ("DartAbstractType* DartTypeDb::FindOrAdd(dart::AbstractTypePtr abTypePtr)\n"
           "{\n"
           "\tswitch (abTypePtr.GetClassId()) {\n")
    new = ("DartAbstractType* DartTypeDb::FindOrAdd(dart::AbstractTypePtr abTypePtr)\n"
           "{\n"
           "\t// fler-dart: tolerant abstract-type dispatch ---------------------------------\n"
           "\t// An empty type slot (raw 0 / null object) must not reach GetClassId().\n"
           "\tif ((intptr_t)abTypePtr == 0 ||\n"
           "\t\t(intptr_t)abTypePtr == (intptr_t)dart::Object::null()) {\n"
           "\t\tstatic bool warned_null = false;\n"
           "\t\tif (!warned_null) {\n"
           "\t\t\tfprintf(stderr, \"fler-dart: null AbstractType slot -> dynamic\\n\");\n"
           "\t\t\twarned_null = true;\n"
           "\t\t}\n"
           "\t\treturn Get(dart::kDynamicCid);\n"
           "\t}\n"
           "\tswitch (abTypePtr.GetClassId()) {\n")
    assert c.count(old) == 1, 'DartTypes.cpp: FindOrAdd head pattern not found'
    c = c.replace(old, new)

    old = ("\t}\n"
           "\t//return nullptr;\n"
           "\tFATAL(\"Invalid abstract type\");\n"
           "}\n")
    new = ("\t}\n"
           "\n"
           "\t// fler-dart: Dart 3.13.x delivers type slots that are none of the subclasses\n"
           "\t// handled above. Aborting here produced SIGABRT (-997) with no clue about what\n"
           "\t// was actually hit, so report the class id once and degrade to `dynamic`.\n"
           "\t{\n"
           "\t\tstatic std::unordered_map<int, int> reported;\n"
           "\t\tconst int cid = (int)abTypePtr.GetClassId();\n"
           "\t\tif (reported.find(cid) == reported.end()) {\n"
           "\t\t\treported[cid] = 1;\n"
           "\t\t\tfprintf(stderr, \"fler-dart: unknown AbstractType cid=%d raw=0x%llx -> dynamic\\n\",\n"
           "\t\t\t\tcid, (unsigned long long)(intptr_t)abTypePtr);\n"
           "\t\t}\n"
           "\t\treturn Get(dart::kDynamicCid);\n"
           "\t}\n"
           "}\n")
    assert c.count(old) == 1, 'DartTypes.cpp: FindOrAdd tail pattern not found'
    c = c.replace(old, new)
    write(name, c)
    print('  DartTypes.cpp: tolerant abstract-type dispatch applied')
else:
    print('  DartTypes.cpp: already patched')

print('  Dart 3.13.x runtime fixes applied')
PYEOF
echo "Dart 3.13.x runtime fixes applied"
