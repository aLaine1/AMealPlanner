; Installeur Windows — construit sous Linux par makensis, depuis tools/release.sh.
;
;   makensis -DVERSION=1.4.5 -DSRC=<dossier windows/> -DTOOLS=<ce dossier> \
;            -DOUT=<fichier setup.exe> installer.nsi
;
; SRC et TOOLS sont des chemins ABSOLUS, en séparateurs Unix : makensis résout les
; chemins relatifs depuis son répertoire de travail et non depuis ce fichier.
;
; Raison d'être : la version portable oblige à supprimer l'ancien dossier puis à
; redécompresser à chaque version, et laisse la possibilité de déplacer l'exécutable
; sans sa DLL — auquel cas l'application démarre puis échoue à ouvrir sa base.
;
; Les DONNÉES ne sont pas concernées : la base et le jeton de compte vivent dans
; %APPDATA%\Godot\app_userdata\AMeal Planner\, hors du dossier d'installation. Ni la
; mise à jour ni la désinstallation n'y touchent — c'est délibéré, et c'est aussi
; pourquoi le désinstalleur ne propose pas de « tout supprimer ».

Unicode true

!define APPNAME "AMeal Planner"
!define COMPANY "A. Laine"
!define EXENAME "AMealPlanner.exe"
!define REGKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\AMealPlanner"

Name "${APPNAME} ${VERSION}"
OutFile "${OUT}"
BrandingText "${APPNAME} ${VERSION}"

; Installation par utilisateur, dans %LOCALAPPDATA%\Programs : pas d'élévation, donc
; pas d'invite administrateur — l'application n'écrit rien hors du profil de toute façon.
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\AMealPlanner"
; Une installation existante est retrouvée et RÉUTILISÉE : sans cela, une mise à jour
; poserait une deuxième copie à côté de la première, laissant deux raccourcis.
InstallDirRegKey HKCU "${REGKEY}" "InstallLocation"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "CompanyName" "${COMPANY}"
VIAddVersionKey "FileDescription" "Installeur de ${APPNAME}"
VIAddVersionKey "FileVersion" "${VERSION}.0"
VIAddVersionKey "ProductVersion" "${VERSION}.0"
VIAddVersionKey "LegalCopyright" "${COMPANY}"

!include "MUI2.nsh"
!define MUI_ICON "${TOOLS}/installer.ico"
!define MUI_UNICON "${TOOLS}/installer.ico"
!define MUI_ABORTWARNING

!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXENAME}"
!define MUI_FINISHPAGE_RUN_TEXT "Lancer ${APPNAME}"

!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "French"

; Windows refuse d'écraser un exécutable en cours d'exécution. Sans ce contrôle,
; l'installation irait jusqu'au bout en laissant l'ANCIENNE version en place, sans
; rien signaler — le pire des résultats pour une mise à jour.
Function .onInit
	reessayer:
	IfFileExists "$INSTDIR\${EXENAME}" 0 suite
		; Le renommage échoue exactement quand la suppression échouerait — fichier
		; verrouillé — mais se défait, là où supprimer priverait de son application
		; quelqu'un qui annulerait l'installation à l'écran suivant.
		ClearErrors
		Rename "$INSTDIR\${EXENAME}" "$INSTDIR\${EXENAME}.verrou"
		IfErrors occupe
		Rename "$INSTDIR\${EXENAME}.verrou" "$INSTDIR\${EXENAME}"
		Goto suite
		occupe:
			MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION \
				"${APPNAME} est en cours d'exécution.$\n$\nFermez l'application, puis cliquez sur Réessayer." \
				IDRETRY reessayer
			Abort
	suite:
FunctionEnd

Section "Application"
	SetOutPath "$INSTDIR"
	; L'exécutable ET la DLL du GDExtension SQLite : séparés, l'application démarre
	; puis échoue à ouvrir sa base.
	File "${SRC}/${EXENAME}"
	File "${SRC}/*.dll"
	File "${TOOLS}/installer.ico"

	CreateDirectory "$SMPROGRAMS\${APPNAME}"
	CreateShortCut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "$INSTDIR\${EXENAME}" "" "$INSTDIR\installer.ico"
	CreateShortCut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\${EXENAME}" "" "$INSTDIR\installer.ico"

	WriteUninstaller "$INSTDIR\uninstall.exe"

	; HKCU et non HKLM : l'installation est par utilisateur, et y écrire ne demanderait
	; pas les mêmes droits.
	WriteRegStr HKCU "${REGKEY}" "DisplayName" "${APPNAME}"
	WriteRegStr HKCU "${REGKEY}" "DisplayVersion" "${VERSION}"
	WriteRegStr HKCU "${REGKEY}" "Publisher" "${COMPANY}"
	WriteRegStr HKCU "${REGKEY}" "DisplayIcon" "$INSTDIR\installer.ico"
	WriteRegStr HKCU "${REGKEY}" "InstallLocation" "$INSTDIR"
	WriteRegStr HKCU "${REGKEY}" "UninstallString" "$\"$INSTDIR\uninstall.exe$\""
	WriteRegDWORD HKCU "${REGKEY}" "NoModify" 1
	WriteRegDWORD HKCU "${REGKEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
	Delete "$INSTDIR\${EXENAME}"
	Delete "$INSTDIR\*.dll"
	Delete "$INSTDIR\installer.ico"
	Delete "$INSTDIR\uninstall.exe"
	RMDir "$INSTDIR"

	Delete "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk"
	RMDir "$SMPROGRAMS\${APPNAME}"
	Delete "$DESKTOP\${APPNAME}.lnk"

	DeleteRegKey HKCU "${REGKEY}"
	; Rien n'est retiré de %APPDATA%\Godot\app_userdata : recettes, rayons et compte
	; survivent à une désinstallation, comme à une mise à jour.
SectionEnd
