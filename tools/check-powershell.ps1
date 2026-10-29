$ErrorActionPreference = 'Stop'
$curriculumRoot = Split-Path -Parent $PSScriptRoot
$markdownFiles = @(Get-ChildItem -LiteralPath (Join-Path $curriculumRoot 'docs') -Recurse -Filter '*.md' -File)
$markdownFiles += Get-Item -LiteralPath (Join-Path $curriculumRoot 'README.md')
$pattern = '(?ms)^(?<fence>`{3,}|~{3,})(?<language>powershell|ps1)[^\r\n]*\r?\n(?<body>.*?)^\k<fence>\s*$'
$failures = [Collections.Generic.List[string]]::new()
$checked = 0
foreach ($markdownFile in $markdownFiles) {
  $content = [IO.File]::ReadAllText($markdownFile.FullName, [Text.Encoding]::UTF8)
  foreach ($match in [regex]::Matches($content, $pattern)) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($match.Groups['body'].Value, [ref]$tokens, [ref]$parseErrors)
    $checked++
    $lineOffset = ($content.Substring(0, $match.Groups['body'].Index) -split "`n").Count - 1
    foreach ($parseError in $parseErrors) {
      $line = $lineOffset + $parseError.Extent.StartLineNumber
      $relative = $markdownFile.FullName.Substring($curriculumRoot.Length + 1)
      $failures.Add(('{0}:{1}: {2}' -f $relative, $line, $parseError.Message))
    }
  }
}
[pscustomobject]@{powerShellVersion=$PSVersionTable.PSVersion.ToString();checkedBlocks=$checked;failures=@($failures.ToArray())} | ConvertTo-Json -Depth 3
if ($failures.Count -gt 0) { exit 1 }
