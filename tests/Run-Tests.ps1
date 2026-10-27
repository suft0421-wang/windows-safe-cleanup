param([string]$SevenZipPath,[string]$TempRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\Backup-RemoveVM.ps1') -LibraryOnly
if(!$TempRoot){$TempRoot=Join-Path ([IO.Path]::GetTempPath()) 'windows-safe-cleanup-tests'}
New-Item -ItemType Directory -Path $TempRoot -Force|Out-Null
$testRoot=Join-Path $TempRoot ('fixture with spaces '+[guid]::NewGuid().ToString('N').Substring(0,8))
$source=Join-Path $testRoot 'source';$nested=Join-Path $source 'nested';$metadata=Join-Path $testRoot 'metadata';$backupDir=Join-Path $testRoot 'backup';$restoreDir=Join-Path $testRoot 'restored'
foreach($dir in @($source,$nested,$metadata,$backupDir,$restoreDir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
$script:taskStage=$backupDir;$script:taskBackupRoot=$backupDir
$outside=Join-Path $testRoot 'keep-project.txt';[IO.File]::WriteAllText($outside,'This project must remain untouched.')
$random=[byte[]]::new(2MB);$rng=[Security.Cryptography.RandomNumberGenerator]::Create();$rng.GetBytes($random);$rng.Dispose()
[IO.File]::WriteAllBytes((Join-Path $source 'random.bin'),$random)
[IO.File]::WriteAllBytes((Join-Path $nested 'disk.bin'),[byte[]]::new(1MB))
[IO.File]::WriteAllText((Join-Path $source '测试项目.txt'),'Important project data: 12345',[Text.UTF8Encoding]::new($false))
$tree=Get-SafeTree $source
$group=[pscustomobject]@{Id='fixture';Root=$source;DriveRoot=[IO.Path]::GetPathRoot($source);Files=$tree.Files;Directories=$tree.Directories;ExtraPaths=@();Config=$null}
$archive=Join-Path $backupDir 'fixture.7z';$sevenZip=Find-SevenZip $SevenZipPath
$backup=New-VerifiedArchive $group $archive $metadata $sevenZip
if($backup.Files.Count -ne 3){throw 'Backup missing fixture files'}
Write-Output 'PASS: complete archive, Unicode filenames, source hashes and archive verification'
$badArchive=Join-Path $backupDir 'corrupt.7z';Copy-Item -LiteralPath $archive -Destination $badArchive
$bad=[IO.File]::Open($badArchive,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$bad.WriteByte(0)}finally{$bad.Dispose()}
$badBackup=$backup.PSObject.Copy();$badBackup.Archive=$badArchive
$rejected=$false;try{Remove-VerifiedSources $group $badBackup}catch{$rejected=$true}
if(!$rejected -or @(Get-ChildItem -LiteralPath $source -File -Recurse).Count -ne 3){throw 'Damaged backup did not preserve all source files'}
Write-Output 'PASS: damaged archive blocks every source deletion'
$record=$backup.Files[0];$original=[IO.File]::ReadAllBytes($record.Path);$changed=[byte[]]$original.Clone();$changed[0]=$changed[0] -bxor 1
[IO.File]::WriteAllBytes($record.Path,$changed);$originalTime=[DateTime]::Parse($record.LastWriteUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
[IO.File]::SetLastWriteTimeUtc($record.Path,$originalTime)
$rejected=$false;try{Remove-VerifiedSources $group $backup}catch{$rejected=$true}
if(!$rejected -or @(Get-ChildItem -LiteralPath $source -File -Recurse).Count -ne 3){throw 'Source content change was not detected'}
[IO.File]::WriteAllBytes($record.Path,$original);[IO.File]::SetLastWriteTimeUtc($record.Path,$originalTime)
Write-Output 'PASS: equal-size, equal-timestamp source change is detected by SHA256'
Remove-VerifiedSources $group $backup
if(Test-Path -LiteralPath $source){throw 'Verified fixture sources were not removed'}
if([IO.File]::ReadAllText($outside) -ne 'This project must remain untouched.'){throw 'Outside project was changed'}
Write-Output 'PASS: verified source removal leaves outside project untouched'
$extract=Invoke-LoggedTool $sevenZip @('x','-y','-sccUTF-8',('-o'+$restoreDir),$archive) $testRoot (Join-Path $metadata 'restore') '还原测试数据'
if($extract.ExitCode -ne 0){throw 'Fixture archive could not be restored'}
foreach($item in $backup.Files){$restored=Join-Path $restoreDir $item.RelativePath;if((Get-FileHash -LiteralPath $restored -Algorithm SHA256).Hash -ine $item.SHA256){throw 'Restored file hash mismatch'}}
Write-Output 'PASS: every restored file matches its original SHA256'
Write-Output ('All safety tests passed. Test files: '+$testRoot)

# Check the reported WSL regression without starting any actual distribution.
if((ConvertTo-NativeCommandLine @('--list','--running','--quiet')) -cne '--list --running --quiet'){throw 'WSL switches must remain unquoted'}
$linux='/bin/bash: line 1: --list: command not found'+[Environment]::NewLine
if((Convert-ToolOutput ([Text.Encoding]::UTF8.GetBytes($linux)) $true) -cne $linux){throw 'Linux UTF8 decoding failed'}
$windows='操作成功完成。'+[Environment]::NewLine+'Ubuntu'
if((Convert-ToolOutput ([Text.Encoding]::Unicode.GetBytes($windows)) $true) -cne $windows){throw 'Windows UTF16 decoding failed'}
Write-Output 'PASS: WSL switch formatting and mixed output encodings; no WSL started'

$guarded=$false
try{Assert-DedicatedVmRoot ([IO.Path]::GetPathRoot($testRoot))}catch{$guarded=$true}
if(!$guarded){throw 'Drive-root protection failed'}
Write-Output 'PASS: VM removal refuses a whole-drive source root'

# Actual preview and apply tests use only a disposable fake Windows profile.
$profile=Join-Path $testRoot 'fake-profile'
$programData=Join-Path $testRoot 'fake-programdata'
$oldPaths=@(
 (Join-Path $profile 'AppData\Local\KOOK\packages\old.nupkg'),
 (Join-Path $profile 'AppData\Local\CrashDumps\old.dmp'),
 (Join-Path $profile 'AppData\Roaming\KOOK\Code Cache\old.bin'),
 (Join-Path $programData 'NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts\old.exe')
)
$keepPaths=@(
 (Join-Path $profile 'Documents\my-project.txt'),
 (Join-Path $profile 'AppData\Local\KOOK\packages\RELEASES.txt'),
 (Join-Path $profile 'AppData\Local\CrashDumps\notes.txt'),
 (Join-Path $profile 'AppData\Roaming\KOOK\Code Cache\fresh.bin')
)
foreach($path in @($oldPaths)+@($keepPaths)){
 $parent=[IO.Path]::GetDirectoryName($path)
 New-Item -ItemType Directory -Path $parent -Force|Out-Null
 [IO.File]::WriteAllText($path,'fixture content')
}
foreach($path in $oldPaths){[IO.File]::SetLastWriteTimeUtc($path,[DateTime]::UtcNow.AddDays(-10))}
$cleanup=Join-Path $PSScriptRoot '..\Clean-Cache.ps1'
& $cleanup -NoPause -UserProfilePath $profile -ProgramDataPath $programData -OutputDirectory (Join-Path $testRoot 'preview-report')|Out-Null
foreach($path in $oldPaths){if(!(Test-Path -LiteralPath $path)){throw 'Default preview deleted a file'}}
Write-Output 'PASS: default cache preview does not delete eligible files'
& $cleanup -Apply -NoPause -UserProfilePath $profile -ProgramDataPath $programData -OutputDirectory (Join-Path $testRoot 'apply-report')|Out-Null
foreach($path in $oldPaths){if(Test-Path -LiteralPath $path){throw 'Explicit cache apply did not remove an eligible file'}}
foreach($path in $keepPaths){if(!(Test-Path -LiteralPath $path)){throw 'Document, fresh cache or excluded file was removed'}}
Write-Output 'PASS: explicit apply deletes only old allowlisted fixture caches'
$summary=Get-Content -LiteralPath (Join-Path $testRoot 'apply-report\cleanup-summary.json') -Raw|ConvertFrom-Json
if($summary.DeletedFiles -ne 4 -or $summary.SkippedFiles -ne 0){throw 'Unexpected cache deletion report'}
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
foreach($scriptFile in Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -Recurse){
 $tokens=$null;$errors=$null
 [Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName,[ref]$tokens,[ref]$errors)|Out-Null
 if($errors.Count){throw ('Syntax errors in '+$scriptFile.FullName)}
}
Write-Output 'PASS: all repository PowerShell scripts parse'
Write-Output 'All tests passed. Tests never remove real virtual machines or user files.'
