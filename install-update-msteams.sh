#!/usr/bin/env bash

# https://github.com/ItzLevvie/MicrosoftTeams-msinternal

# to operate non-interactively (avoiding password prompts for sudo commands)
# you will need to make use of SUDO_ASKPASS. You can read more about this at:
# https://www.sudo.ws/docs/man/sudo.man/#A or `man sudo`

set -o pipefail

# Homebrew required!
if ! hash brew &>/dev/null; then
  echo >&2 "Install Homebrew first! Visit https://brew.sh"
  exit 1
fi

# poor man's prereq check
for f in dockutil pwsh:powershell ; do
  if ! hash "${f%%:*}" &>/dev/null; then brew install --quiet "${f##*:}"; fi
done

BUNDLE_ID='com.microsoft.teams2'
APP_NAME=$(mdfind kMDItemCFBundleIdentifier == $BUNDLE_ID 2>/dev/null)
if [[ -n $APP_NAME ]]; then
  APP_NAME=${APP_NAME##*/}
else
  APP_NAME="Microsoft Teams.app"
fi
DL_PATH='/private/tmp'
REPO='ItzLevvie/MicrosoftTeams-msinternal'
PS_SCRIPT_DIR="/usr/local/bin"
PS_SCRIPT='Get-MicrosoftTeams.ps1'
PS_SCRIPT_FQPN="/usr/local/bin/$PS_SCRIPT"
DOCK_AFTER='Messages' #position to place Teams icon in Dock
mkdir -p "$PS_SCRIPT_DIR"

function _die() {
  # params: $1=message $2=exit code (default=1)
  [[ -n $1 ]] && echo >&2 "$1"
  [[ -n $2 ]] && exit "$2" || exit 1
}

function _getInfoVer() {
  [[ -d $1 ]] || { echo >&2 "app $1 not found"; return 1; }
  local plist="${1%/}/Contents/Info.plist"
  [[ -e $plist ]] || return 1
  /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null
}

function _ver_bv() {
  local a
  mapfile -t a < <(mdfind -onlyin /Applications kMDItemCFBundleIdentifier == "$1")
  _getInfoVer "${a[0]}"
}

function _download() {
  local fname=${1##*/}
  CURLOPTS=( --silent --location --remote-name --connect-timeout 10 --output-dir "$DL_PATH" )
  echo "attempting to download $fname"
  if ! curl "${CURLOPTS[@]}" "$1" || [[ ! -s ${DL_PATH}/${fname} ]] ; then
    return 1
  fi
}

# fetch Get-MicrosoftTeams pwsh script
if [[ ! -s $PS_SCRIPT_FQPN ]]; then
  echo "downloading $PS_SCRIPT script"
  curl \
  --location \
  --clobber \
  --progress-bar \
  --output "$PS_SCRIPT_FQPN" \
  https://github.com/$REPO/raw/master/src/$PS_SCRIPT
fi

# get URL of installer .pkg
read -r pkg_url < <(
  pwsh -noni -nop "$PS_SCRIPT_FQPN" \
    -Environment prod \
    -Ring ring2 \
    -Platform 'osx-x64 + osx-arm64' \
    -Version 2.1 \
    -Client Desktop |
  awk '$NF ~ /^https/ { print $NF }')
read -r ver < <(awk -F/ '{print $(NF-1)}' <<< "$pkg_url")

#ensure that url is valid, fall back to staticsint if not
rc=$(curl -ILso /dev/null -w "%{http_code}" "$pkg_url")
if (( rc != 200 )); then
  echo >&2 "rc=$rc, swapping statics => staticsint in pkg URL"
  url_tmpl='https://staticsint.teams.cdn.office.net/production-osx/#/MicrosoftTeams.pkg'
  pkg_url=${url_tmpl/\#/$ver}
fi

if [[ -z $pkg_url ]]; then
  _die "error fetching latest build information"
fi

pkg_filename=${pkg_url##*/}
cur_ver=$(_ver_bv $BUNDLE_ID 2>/dev/null)
[[ ${cur_ver} == "${ver}" ]] && _die "${APP_NAME%.app} v${cur_ver} already installed and up to date" 0
if [[ -n $cur_ver ]]; then
  echo "current installed version: $cur_ver"
  echo "version from API is: $ver"
fi

# is app running?
APP_PID=$(pgrep -x MSTeams)
[[ -z $APP_PID ]] || _die "Please quit ${APP_NAME%.app} first, then try again"

# download
[[ -e ${DL_PATH}/${pkg_filename} ]] && rm "${DL_PATH}/${pkg_filename}"
_download "${pkg_url}" || _die "download failed"

#remove all existing previous versions
mapfile -t appArray < <(mdfind -onlyin /Applications 'kMDItemCFBundleIdentifier == "com.microsoft.teams" || kMDItemCFBundleIdentifier == "com.microsoft.teams2"')
for a in "${appArray[@]}"; do
  echo "deleting $a"
  sudo ${SUDO_ASKPASS:+-A} rm -rf "$a" &>/dev/null
done

#install pkg
echo "installing ${pkg_filename}..."
if ! sudo ${SUDO_ASKPASS:+-A} /usr/sbin/installer -pkg "${DL_PATH}/${pkg_filename}" -target / ; then
  _die "error installing ${APP_NAME%.app}"
else
  if command -v dockutil &>/dev/null; then
    if dockutil --find $BUNDLE_ID &>/dev/null; then
      dockutil --remove $BUNDLE_ID &>/dev/null
    fi
    dockutil --add "/Applications/$APP_NAME" --after $DOCK_AFTER &>/dev/null
  fi
  audiodrv="/Applications/${APP_NAME}/Contents/SharedSupport/MSTeamsAudioDevice.pkg"
  td_tmp_dir='/private/tmp/teamsdrv'
  td='MSTeamsAudioDevice.driver/Contents/MacOS/MSTeamsAudioDevice'
  if [[ -e $audiodrv ]]; then
    rm -rf $td_tmp_dir 2>/dev/null
    pkgutil --expand-full "$audiodrv" $td_tmp_dir/
    if [[ -e $td_tmp_dir/Payload/$td ]]; then
      if ! diff -q $td_tmp_dir/Payload/$td /Library/Audio/Plug-Ins/HAL/$td &>/dev/null; then
        echo "installing updated Teams Audio Driver"
        sudo ${SUDO_ASKPASS:+-A} /usr/sbin/installer -pkg "$audiodrv" -target /
        sudo ${SUDO_ASKPASS:+-A} killall -q coreaudiod #bounce coreaudio otherwise we may lose sound
      fi
    fi
  fi
  #comment out the following 'sudo...' lines if you want to leave the native autoupdate mechanism in place
  sudo ${SUDO_ASKPASS:+-A} launchctl remove com.microsoft.teams.TeamsUpdaterDaemon 2>/dev/null
  sudo ${SUDO_ASKPASS:+-A} launchctl remove com.microsoft.autoupdate.helper 2>/dev/null
  sudo ${SUDO_ASKPASS:+-A} launchctl remove com.microsoft.update.agent 2>/dev/null
  sudo ${SUDO_ASKPASS:+-A} rm /Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist 2>/dev/null
  sudo ${SUDO_ASKPASS:+-A} rm /Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist 2>/dev/null
  sudo ${SUDO_ASKPASS:+-A} rm /Library/LaunchAgents/com.microsoft.update.agent.plist 2>/dev/null

  echo "${APP_NAME%.app} has been installed/updated"
  n_ver=$(_getInfoVer "/Applications/$APP_NAME")
  [[ -n $n_ver ]] && echo "new version: $n_ver"
  rm "${DL_PATH:?}/${pkg_filename}"
fi
