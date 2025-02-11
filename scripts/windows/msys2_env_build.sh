# Msys2 config
export MSYS=winsymlinks:nativestrict

if [ "${MSYSTEM}" = "" -o "${MSYSTEM}" = "MSYS" ]; then
    export MSYSTEM="MINGW64"
fi

make_winpath()
{
    P=$1
    if [ "$IN_CYGWIN" = "true" ]; then
        cygpath -d "$P"
    else
        (cd "$P" && /bin/cmd //C "for %i in (".") do @echo %~fsi")
    fi
}

make_upath()
{
    P=$1
    if [ "$IN_CYGWIN" = "true" ]; then
        cygpath "$P"
    else
        echo "$P" | /bin/sed 's,^\([a-zA-Z]\):\\,/\L\1/,;s,\\,/,g'
    fi
}

# Without this the path conversion won't work
COMSPEC='C:\Windows\System32\cmd.exe'

obe_otp_gcc_vsn_map="
    .*=>default
"
obe_otp_64_gcc_vsn_map="
    .*=>default
"

C_DRV="/c"
WIN_C_DRV="C:\\"
IN_CYGWIN=false
CPPFLAGS='-D _WIN32'

MSYS2_ROOT=${MSYS2_ROOT:-"${C_DRV}/msys64"}
WIN_MSYS2_ROOT=${WIN_MSYS2_ROOT:-"${WIN_C_DRV}\\msys64"}

PRG_FLS64="$(make_upath "${PROGRAMFILES}")"
WIN_PRG_FLS64="${PROGRAMFILES}"
ERL_TOP="${PRG_FLS64}/erl${ERTS_VERSION}"
WIN_ERL_TOP="${WIN_PRG_FLS64}\\erl${ERTS_VERSION}"
JAVA_TOP="${JAVA_TOP:-${PRG_FLS64}/Java/jdk-${JAVA_VERSION}}"

WIN_VISUAL_STUDIO_ROOT="${VSINSTALLDIR}"
VISUAL_STUDIO_ROOT="$(make_upath "${WIN_VISUAL_STUDIO_ROOT}")"

WIN_MSVC_ROOT=${VCToolsInstallDir}
WIN_MSVC=${WIN_MSVC_ROOT}bin\\Hostx64\\x64

MSVC_ROOT="$(make_upath "${WIN_MSVC_ROOT}")"
MSVC="$(make_upath "${WIN_MSVC}")"

PATH="/usr/local/bin:/usr/bin:/bin:/c/Windows/system32:/c/Windows:/c/Windows/System32/Wbem:${PATH}"
PATH="${HOME}/.local/bin:${MSVC}:${ERL_TOP}/bin:${PATH}:${ERL_TOP}/erts-${ERTS_VERSION}/bin:${MSYS2_ROOT}/mingw64/bin"
PATH="${JAVA_TOP}/bin:${PATH}"

INCLUDE="${INCLUDE};${WIN_MSYS2_ROOT}\\mingw64\\include;${WIN_MSYS2_ROOT}\\usr\\include"
LIB="${LIB};${WIN_MSYS2_ROOT}\\mingw64\\lib;${WIN_MSYS2_ROOT}\\mingw64\\bin;${WIN_ERL_TOP}\\usr\\lib;"

export INCLUDE LIB PATH ERL_TOP WIN_ERL_TOP COMSPEC CPPFLAGS
