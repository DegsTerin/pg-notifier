#define AppName "PgNotifier"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\PgNotifier-" + AppVersion
#endif

[Setup]
AppId={{3E7DDA86-B53C-4265-A1C3-2B7A87620B91}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Open Source
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
OutputDir=..\dist\installer
OutputBaseFilename=PgNotifier-Setup-{#AppVersion}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "startup"; Description: "Iniciar com o Windows"; GroupDescription: "Opcoes adicionais:"; Flags: unchecked
Name: "desktopicon"; Description: "Criar atalho na Area de Trabalho"; GroupDescription: "Opcoes adicionais:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\PgNotifier.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\config\appsettings.json"; DestDir: "{commonappdata}\PgNotifier"; Flags: ignoreversion onlyifdoesntexist

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\PgNotifier.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\PgNotifier.exe"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\PgNotifier.exe"; Parameters: "-ConfigPath ""{commonappdata}\PgNotifier\appsettings.json"""; Tasks: startup

[Run]
Filename: "{app}\PgNotifier.exe"; Parameters: "-ConfigPath ""{commonappdata}\PgNotifier\appsettings.json"""; Description: "Executar {#AppName}"; Flags: nowait postinstall skipifsilent
