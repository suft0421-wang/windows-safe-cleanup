param([string]$Path=($env:SystemDrive+'\'),[string]$OutputPath)
$ErrorActionPreference='Continue'
$taskStarted=Get-Date
$taskStats=@{}
$taskLarge=[System.Collections.Generic.List[object]]::new()
$taskSkipped=[System.Collections.Generic.List[string]]::new()
$taskQueue=[System.Collections.Generic.Queue[string]]::new()
$taskQueue.Enqueue([IO.Path]::GetFullPath($Path))
$taskFileCount=0
$taskDirCount=0
while($taskQueue.Count -gt 0){
 $taskDir=$taskQueue.Dequeue()
 $taskDirCount++
 try{
  foreach($taskFile in [System.IO.DirectoryInfo]::new($taskDir).EnumerateFiles()){
   if(($taskFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0){continue}
   $taskFileCount++
   $taskSize=$taskFile.Length
   $taskParts=$taskFile.DirectoryName.Split('\',[System.StringSplitOptions]::RemoveEmptyEntries)
   $taskKey=$taskParts[0]
   for($taskI=1;$taskI -lt [Math]::Min($taskParts.Length,6);$taskI++){
    $taskKey+='\'+$taskParts[$taskI]
    if(!$taskStats.ContainsKey($taskKey)){$taskStats[$taskKey]=[long]0}
    $taskStats[$taskKey]+=$taskSize
   }
   if($taskSize -ge 150MB){$taskLarge.Add([pscustomobject]@{Path=$taskFile.FullName;Bytes=$taskSize;GB=[math]::Round($taskSize/1GB,3);LastWrite=$taskFile.LastWriteTime})}
  }
 }catch{$taskSkipped.Add($taskDir+' [files]')}
 try{
  foreach($taskSubdir in [System.IO.DirectoryInfo]::new($taskDir).EnumerateDirectories()){
   if(($taskSubdir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0){$taskQueue.Enqueue($taskSubdir.FullName)}
  }
 }catch{$taskSkipped.Add($taskDir+' [directories]')}
 if(($taskDirCount % 10000) -eq 0){Write-Output "Scanned $taskDirCount directories, $taskFileCount files"}
}
$taskResult=[pscustomobject]@{
 Started=$taskStarted;Finished=(Get-Date);Files=$taskFileCount;Directories=$taskDirCount
 Folders=@($taskStats.GetEnumerator() | ForEach-Object {[pscustomobject]@{Path=$_.Key;Bytes=$_.Value;GB=[math]::Round($_.Value/1GB,3)}} | Sort-Object Bytes -Descending)
 LargeFiles=@($taskLarge | Sort-Object Bytes -Descending)
 Skipped=@($taskSkipped)
}
if($OutputPath){
 $fullOutput=[IO.Path]::GetFullPath($OutputPath)
 $outputParent=[IO.Path]::GetDirectoryName($fullOutput)
 if(!(Test-Path -LiteralPath $outputParent)){New-Item -ItemType Directory -Path $outputParent -Force|Out-Null}
 $taskResult | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fullOutput -Encoding utf8
}
$taskResult | Select-Object Started,Finished,Files,Directories | ConvertTo-Json
$taskResult.Folders | Select-Object -First 60 | ConvertTo-Json
$taskResult.LargeFiles | Select-Object -First 35 | ConvertTo-Json