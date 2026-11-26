<#
.SYNOPSIS
    KINTAI Deterministic DDL Metadata Extractor (extract_ddl_spec.ps1)
.DESCRIPTION
    Statically extracts deterministic table metadata, exact physical column counts,
    column names, PK, FK, and CHECK constraints from schema.sql.
#>
[CmdletBinding()]
param(
    [string]$DdlPath = "domain_target/02_database_schema_ssot/schema.sql",
    [string]$TableName = "",
    [string]$OutputPath = "",
    [switch]$ReportOnly = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Get-FileSystemPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Test-Identifier([string]$Token) {
    return $Token -cmatch '^(?:[\p{L}_][\p{L}\p{Nd}_$]*|"(?:[^"]|"")+"|`(?:[^`]|``)+`|\[(?:[^\]]|\]\])+\])\z'
}

function Convert-Identifier([string]$Token) {
    if (-not (Test-Identifier $Token)) {
        throw "Expected SQL identifier, found '$Token'."
    }
    switch ($Token[0]) {
        '"' { return $Token.Substring(1, $Token.Length - 2).Replace('""', '"') }
        '`' { return $Token.Substring(1, $Token.Length - 2).Replace('``', '`') }
        '[' { return $Token.Substring(1, $Token.Length - 2).Replace(']]', ']') }
        default { return $Token }
    }
}

function Get-Token([int]$Index) {
    if ($Index -ge 0 -and $Index -lt $tokens.Count) {
        return $tokens[$Index].Value
    }
    return ''
}

function Read-QualifiedName([ref]$Cursor) {
    $i = [int]$Cursor.Value
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((Convert-Identifier (Get-Token $i)))
    $i++
    while ((Get-Token $i) -eq '.') {
        $parts.Add((Convert-Identifier (Get-Token ($i + 1))))
        $i += 2
    }
    $Cursor.Value = $i
    return ($parts -join '.')
}

function Read-KeyColumns([ref]$Cursor) {
    $i = [int]$Cursor.Value
    if ((Get-Token $i) -ne '(') {
        throw "Expected a key column list at token $i."
    }
    $end = $closing[$i]
    $i++
    $cols = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $cols.Add((Convert-Identifier (Get-Token $i)))
        $i++
        if ((Get-Token $i) -in @('ASC', 'DESC')) { $i++ }
        if ($i -eq $end) { break }
        if ((Get-Token $i) -ne ',') {
            throw "Unsupported key column syntax at token $i."
        }
        $i++
    }
    $Cursor.Value = $end + 1
    return $cols.ToArray()
}

function Add-PrimaryKey([string[]]$Names) {
    if ($primary.Count -gt 0) { throw "Multiple primary keys in '$table'." }
    foreach ($name in $Names) { $primary.Add($name) }
}

function Read-Reference([ref]$Cursor, [string[]]$LocalColumns, $Name) {
    $i = [int]$Cursor.Value
    if ((Get-Token $i) -ne 'REFERENCES') {
        throw "Expected REFERENCES in '$table' at token $i."
    }
    $i++
    $target = Read-QualifiedName ([ref]$i)
    $remote = @(Read-KeyColumns ([ref]$i))
    if ($LocalColumns.Count -ne $remote.Count) {
        throw "Foreign key column count mismatch in '$table'."
    }
    for ($j = 0; $j -lt $remote.Count; $j++) {
        $foreign.Add([ordered]@{
            name       = $Name
            column     = $LocalColumns[$j]
            ref_table  = $target
            ref_column = $remote[$j]
        })
    }
    $Cursor.Value = $i
}

function Read-Check([ref]$Cursor, $Name) {
    $open = [int]$Cursor.Value + 1
    if ((Get-Token $open) -ne '(') {
        throw "Expected parenthesized CHECK in '$table'."
    }
    $end = $closing[$open]
    if ($end -eq $open + 1) { throw "Empty CHECK in '$table'." }
    $start = $tokens[$open].Index + 1
    $checks.Add([ordered]@{
        name      = $Name
        condition = $sql.Substring($start, $tokens[$end].Index - $start).Trim()
    })
    $Cursor.Value = $end + 1
}

function Read-Definition([int]$First, [int]$End) {
    if ($First -ge $End) { throw "Empty definition in '$table'." }
    $i = $First
    $constraintName = $null
    $named = (Get-Token $i) -eq 'CONSTRAINT'
    if ($named) {
        $constraintName = Convert-Identifier (Get-Token ($i + 1))
        $i += 2
    }

    switch (Get-Token $i) {
        'PRIMARY' {
            if ((Get-Token ($i + 1)) -ne 'KEY') { throw "Invalid PRIMARY KEY in '$table'." }
            $i += 2
            Add-PrimaryKey @(Read-KeyColumns ([ref]$i))
            return
        }
        'FOREIGN' {
            if ((Get-Token ($i + 1)) -ne 'KEY') { throw "Invalid FOREIGN KEY in '$table'." }
            $i += 2
            if (Test-Identifier (Get-Token $i)) { $i++ }
            $localColumns = @(Read-KeyColumns ([ref]$i))
            Read-Reference ([ref]$i) $localColumns $constraintName
            return
        }
        'CHECK' {
            Read-Check ([ref]$i) $constraintName
            return
        }
        { $_ -in @('UNIQUE', 'KEY', 'INDEX', 'FULLTEXT', 'SPATIAL', 'EXCLUDE') } {
            return
        }
        { $_ -in @('LIKE', 'PERIOD') } {
            throw "Unsupported table element '$_' in '$table'."
        }
    }

    if ($named) { throw "Unknown table constraint '$constraintName' in '$table'." }
    $column = Convert-Identifier (Get-Token $i)
    if (++$i -ge $End) { throw "Missing type for '$table.$column'." }
    if (-not $seenColumns.Add($column)) { throw "Duplicate column '$table.$column'." }
    $columns.Add($column)

    while ($i -lt $End) {
        $token = Get-Token $i
        if ($token -eq '(') {
            $i = $closing[$i] + 1
            continue
        }
        if ($token -eq 'CONSTRAINT') {
            $constraintName = Convert-Identifier (Get-Token ($i + 1))
            $i += 2
            continue
        }
        if ($token -eq 'PRIMARY' -and (Get-Token ($i + 1)) -eq 'KEY') {
            Add-PrimaryKey @($column)
            $i += 2
        }
        elseif ($token -eq 'REFERENCES') {
            Read-Reference ([ref]$i) @($column) $constraintName
        }
        elseif ($token -eq 'CHECK') {
            Read-Check ([ref]$i) $constraintName
        }
        else {
            $i++
        }
        $constraintName = $null
    }
}

$fullPath = Get-FileSystemPath $DdlPath
$source = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)

$pattern = @'
\G(?:
    (?<space>\s+)
  | (?<comment>--[^\r\n]*|/\*(?:(?!/\*|\*/)[\s\S])*\*/)
  | '(?:[^']|'')*'
  | "(?:[^"]|"")*"
  | `(?:[^`]|``)*`
  | \[(?:[^\]]|\]\])*\]
  | [\p{L}_][\p{L}\p{Nd}_$]*
  | [0-9]+
  | (?!/\*|\*/|['"`\[])[^\s]
)
'@
$lexer = [regex]::new($pattern, [Text.RegularExpressions.RegexOptions]::IgnorePatternWhitespace)
$builder = [Text.StringBuilder]::new()
$tokens = [System.Collections.Generic.List[object]]::new()
$offset = 0
foreach ($match in $lexer.Matches($source)) {
    if ($match.Groups['comment'].Success) {
        [void]$builder.Append(' ')
    }
    else {
        if (-not $match.Groups['space'].Success) {
            $tokens.Add([pscustomobject]@{ Value = $match.Value; Index = $builder.Length })
        }
        [void]$builder.Append($match.Value)
    }
    $offset += $match.Length
}
if ($offset -ne $source.Length) {
    throw "Malformed quote or unsupported block comment at character $offset in '$fullPath'."
}
$sql = $builder.ToString()

$closing = @{}
$stack = [System.Collections.Generic.Stack[int]]::new()
for ($i = 0; $i -lt $tokens.Count; $i++) {
    switch ($tokens[$i].Value) {
        '(' { $stack.Push($i) }
        ')' {
            if ($stack.Count -eq 0) { throw "Unmatched ')' at token $i." }
            $closing[$stack.Pop()] = $i
        }
    }
}
if ($stack.Count -gt 0) { throw "Unmatched '(' at token $($stack.Peek())." }

$result = [System.Collections.Generic.List[object]]::new()
$seenTables = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
for ($i = 0; $i -lt $tokens.Count; $i++) {
    if ((Get-Token $i) -eq 'ALTER' -and (Get-Token ($i + 1)) -eq 'TABLE') {
        throw "ALTER TABLE at token $i requires migration-aware extraction."
    }
    if ((Get-Token $i) -ne 'CREATE') { continue }
    $j = $i + 1
    if ((Get-Token $j) -in @('TEMP', 'TEMPORARY', 'UNLOGGED')) { $j++ }
    if ((Get-Token $j) -ne 'TABLE') { continue }
    $j++
    if ((Get-Token $j) -eq 'IF') {
        if ((Get-Token ($j + 1)) -ne 'NOT' -or (Get-Token ($j + 2)) -ne 'EXISTS') {
            throw "Malformed IF NOT EXISTS at token $j."
        }
        $j += 3
    }
    $table = Read-QualifiedName ([ref]$j)
    if ((Get-Token $j) -ne '(') { throw "Expected explicit column definitions for '$table'." }
    $end = $closing[$j]
    $i = $end
    if (-not $seenTables.Add($table)) { throw "Duplicate definition of '$table'." }
    if ($TableName.Length -gt 0 -and $table -ine $TableName) { continue }

    $columns = [System.Collections.Generic.List[string]]::new()
    $seenColumns = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $primary = [System.Collections.Generic.List[string]]::new()
    $foreign = [System.Collections.Generic.List[object]]::new()
    $checks = [System.Collections.Generic.List[object]]::new()

    $first = $j + 1
    for ($k = $first; $k -lt $end; $k++) {
        switch ($tokens[$k].Value) {
            '(' { $k = $closing[$k] }
            ',' {
                Read-Definition $first $k
                $first = $k + 1
            }
        }
    }
    Read-Definition $first $end
    foreach ($keyColumn in $primary) {
        if ($columns -cnotcontains $keyColumn) { throw "Unknown PK column '$table.$keyColumn'." }
    }
    foreach ($key in $foreign) {
        if ($columns -cnotcontains $key.column) { throw "Unknown FK column '$table.$($key.column)'." }
    }

    $result.Add([ordered]@{
        table_name        = $table
        column_count      = $columns.Count
        columns           = $columns.ToArray()
        primary_key       = $primary.ToArray()
        foreign_keys      = $foreign.ToArray()
        check_constraints = $checks.ToArray()
    })
}

if ($result.Count -eq 0) {
    if ($TableName.Length -gt 0) { throw "Table '$TableName' was not found in '$fullPath'." }
    throw "No CREATE TABLE definitions were found in '$fullPath'."
}
if ($TableName.Length -gt 0 -and $result.Count -gt 1) {
    throw "Table filter '$TableName' matched multiple definitions."
}

$json = ConvertTo-Json -InputObject ($result.ToArray()) -Depth 5
if ($OutputPath.Length -eq 0) {
    $json
}
else {
    $destination = Get-FileSystemPath $OutputPath
    if ([string]::Equals($fullPath, $destination, [StringComparison]::OrdinalIgnoreCase)) {
        throw "OutputPath must differ from DdlPath."
    }
    [System.IO.File]::WriteAllText($destination, $json, [System.Text.UTF8Encoding]::new($false))
}
