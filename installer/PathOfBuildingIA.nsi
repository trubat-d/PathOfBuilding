; Path of Building IA: one-file installer (NSIS). Built by installer/build.sh,
; which stages the files in STAGE first:
;   web installer: the runtime, Launch / UpdateCheck / UpdateApply, a manifest
;   and first.run - the first start downloads the rest from GitHub with Path of
;   Building's own updater, and every later start offers the new versions
;   full installer (FULL=1): every file, nothing downloaded
; Installed per user (no administrator rights), next to and apart from the
; official Path of Building: its own folder, its own builds and settings
; (the program keeps them in its folder, as a portable copy).
Unicode true
!include "MUI2.nsh"

!define APPNAME "Path of Building IA"
!define APPKEY "PathOfBuildingIA"
!define EXE "Path of Building.exe"

Name "${APPNAME}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
InstallDirRegKey HKCU "Software\${APPKEY}" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "${APPNAME} ${VERSION}"

!define MUI_ICON "pob.ico"
!define MUI_UNICON "pob.ico"
!define MUI_WELCOMEPAGE_TEXT "This installs ${APPNAME} (version ${VERSION}), Path of Building with the build generator.$\r$\n$\r$\nIt is installed apart from the official Path of Building: its own folder, builds and settings.${WELCOMEEXTRA}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "Start ${APPNAME}"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Section "Install"
	SetOutPath "$INSTDIR"
	File /r "${STAGE}\*"
	WriteUninstaller "$INSTDIR\Uninstall.exe"
	WriteRegStr HKCU "Software\${APPKEY}" "InstallDir" "$INSTDIR"
	WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "DisplayName" "${APPNAME}"
	WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "DisplayVersion" "${VERSION}"
	WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "DisplayIcon" "$INSTDIR\${EXE}"
	WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
	WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "NoModify" 1
	WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}" "NoRepair" 1
	CreateDirectory "$SMPROGRAMS\${APPNAME}"
	CreateShortcut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "$INSTDIR\${EXE}"
	CreateShortcut "$SMPROGRAMS\${APPNAME}\Uninstall ${APPNAME}.lnk" "$INSTDIR\Uninstall.exe"
	CreateShortcut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\${EXE}"
SectionEnd

; (the program only: builds, settings and what the generator learned stay -
; Builds, Settings.xml, Generator*.json*, BuildIdeas*.json, GenerationQueue)
Section "Uninstall"
	RMDir /r "$INSTDIR\Assets"
	RMDir /r "$INSTDIR\Classes"
	RMDir /r "$INSTDIR\Data"
	RMDir /r "$INSTDIR\Modules"
	RMDir /r "$INSTDIR\TreeData"
	RMDir /r "$INSTDIR\lua"
	RMDir /r "$INSTDIR\SimpleGraphic"
	RMDir /r "$INSTDIR\Update"
	Delete "$INSTDIR\*.dll"
	Delete "$INSTDIR\*.lua"
	Delete "$INSTDIR\${EXE}"
	Delete "$INSTDIR\Update.exe"
	Delete "$INSTDIR\manifest.xml"
	Delete "$INSTDIR\first.run"
	Delete "$INSTDIR\changelog.txt"
	Delete "$INSTDIR\help.txt"
	Delete "$INSTDIR\LICENSE.md"
	Delete "$INSTDIR\imgui.ini"
	Delete "$INSTDIR\SimpleGraphic.cfg"
	Delete "$INSTDIR\SimpleGraphic.log"
	Delete "$INSTDIR\Uninstall.exe"
	RMDir "$INSTDIR"
	Delete "$DESKTOP\${APPNAME}.lnk"
	RMDir /r "$SMPROGRAMS\${APPNAME}"
	DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}"
	DeleteRegKey HKCU "Software\${APPKEY}"
SectionEnd
