param([string]$TerraformCommand = 'terraform')
$ErrorActionPreference = 'Stop'
$curriculumRoot = Split-Path -Parent $PSScriptRoot
$terraformPath = (Get-Command $TerraformCommand -ErrorAction Stop).Source
$pattern = '(?ms)^(?<fence>`{3,}|~{3,})(hcl|terraform)[^\r\n]*\r?\n(?<body>.*?)^\k<fence>\s*$'
$failures = [Collections.Generic.List[string]]::new()
$checked = 0
foreach ($markdownFile in Get-ChildItem -LiteralPath (Join-Path $curriculumRoot 'docs/delivery') -Filter '*.md' -File) {
  $content = [IO.File]::ReadAllText($markdownFile.FullName, [Text.Encoding]::UTF8)
  foreach ($match in [regex]::Matches($content, $pattern)) {
    $temporaryFile = Join-Path ([IO.Path]::GetTempPath()) ('iam-hcl-' + [guid]::NewGuid().ToString('N') + '.tf')
    try {
      [IO.File]::WriteAllText($temporaryFile, $match.Groups['body'].Value, [Text.UTF8Encoding]::new($false))
      $start = [Diagnostics.ProcessStartInfo]::new()
      $start.FileName = $terraformPath
      $start.Arguments = 'fmt -write=false -list=false -no-color "' + $temporaryFile + '"'
      $start.UseShellExecute = $false
      $start.CreateNoWindow = $true
      $start.RedirectStandardOutput = $true
      $start.RedirectStandardError = $true
      $process = [Diagnostics.Process]::Start($start)
      $output = $process.StandardOutput.ReadToEnd()
      $errorOutput = $process.StandardError.ReadToEnd()
      $process.WaitForExit()
      $checked++
      if ($process.ExitCode -ne 0) {
        $line = ($content.Substring(0, $match.Groups['body'].Index) -split "`n").Count
        $failures.Add(('{0}:{1}: {2}{3}' -f $markdownFile.Name, $line, $output, $errorOutput))
      }
      $process.Dispose()
    } finally {
      if (Test-Path -LiteralPath $temporaryFile) { Remove-Item -LiteralPath $temporaryFile -Force }
    }
  }
}
[pscustomobject]@{checkedHclBlocks=$checked;failures=@($failures.ToArray());scope='syntax only; no init/validate/plan/apply'} | ConvertTo-Json -Depth 3
if ($failures.Count -gt 0) { exit 1 }
