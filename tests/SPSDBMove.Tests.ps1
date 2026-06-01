#Requires -Version 7.0
#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.3.0' }

<#
.SYNOPSIS
    Static-analysis and parser smoke tests for scripts/SPSDBMove.ps1.

.DESCRIPTION
    These tests do not require SQL Server. They validate that the script:
      * exists at the expected location,
      * parses cleanly with the PowerShell language parser,
      * requires PowerShell 7.0+,
      * exposes the documented parameters,
      * passes PSScriptAnalyzer at Error and Warning severity.

    A second describe block validates structural metadata of the repository
    (README, CHANGELOG, LICENSE, etc.) so that CI catches drift early.
#>

BeforeDiscovery {
    $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:ScriptPath = Join-Path $script:RepoRoot 'scripts/SPSDBMove.ps1'
}

Describe 'scripts/SPSDBMove.ps1 — parser and signature' {

    BeforeAll {
        $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..')
        $script:ScriptPath = Join-Path $script:RepoRoot 'scripts/SPSDBMove.ps1'
    }

    It 'exists at scripts/SPSDBMove.ps1' {
        Test-Path -LiteralPath $script:ScriptPath | Should -BeTrue
    }

    It 'parses without syntax errors' {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'requires PowerShell 7.0 or later' {
        $content = Get-Content -LiteralPath $script:ScriptPath -Raw
        $content | Should -Match '#Requires\s+-Version\s+7\.0'
    }

    It 'declares CmdletBinding with SupportsShouldProcess' {
        $content = Get-Content -LiteralPath $script:ScriptPath -Raw
        $content | Should -Match '\[CmdletBinding\([^\)]*SupportsShouldProcess'
    }

    It 'exposes the documented top-level parameters' {
        $expected = @(
            'ConfigPath',
            'Action',
            'SqlCredential',
            'SkipExisting'
        )

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        $paramBlock = $ast.ParamBlock
        $paramBlock | Should -Not -BeNullOrEmpty

        $declared = $paramBlock.Parameters.Name.VariablePath.UserPath
        foreach ($name in $expected) {
            $declared | Should -Contain $name -Because "parameter -$name is part of the documented surface"
        }

        $declared.Count | Should -Be $expected.Count `
            -Because 'all job-level options live in the JSON config, not the CLI'
    }

    It 'marks -ConfigPath as mandatory' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ScriptPath, [ref]$tokens, [ref]$errors)

        $configParam = $ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ConfigPath' }
        $configParam | Should -Not -BeNullOrEmpty

        $mandatoryArg = $configParam.Attributes |
            Where-Object { $_.TypeName.Name -eq 'Parameter' } |
            ForEach-Object { $_.NamedArguments } |
            Where-Object { $_.ArgumentName -eq 'Mandatory' }
        $mandatoryArg | Should -Not -BeNullOrEmpty
    }
}

Describe 'scripts/SPSDBMove.sample.json — JSON config sample' {

    BeforeAll {
        $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
        $script:SamplePath = Join-Path $script:RepoRoot 'scripts/SPSDBMove.sample.json'
    }

    It 'exists at scripts/SPSDBMove.sample.json' {
        Test-Path -LiteralPath $script:SamplePath | Should -BeTrue
    }

    It 'is valid JSON' {
        { Get-Content -LiteralPath $script:SamplePath -Raw | ConvertFrom-Json -ErrorAction Stop } |
            Should -Not -Throw
    }

    It 'declares every documented top-level key' {
        $json = Get-Content -LiteralPath $script:SamplePath -Raw | ConvertFrom-Json
        $expected = @(
            'SourceInstance', 'DestinationInstance',
            'SourceBackupRoot', 'DestinationBackupRoot',
            'DataFileDirectory', 'LogFileDirectory',
            'ThrottleLimit',
            'OverwriteDestinationDb', 'Databases',
            'ExcludeDatabases'
        )
        foreach ($key in $expected) {
            $json.PSObject.Properties.Name | Should -Contain $key
        }
    }
}

Describe 'scripts/SPSDBMove.ps1 — PSScriptAnalyzer' -Tag 'ScriptAnalyzer' {

    BeforeAll {
        $script:RepoRoot   = Resolve-Path (Join-Path $PSScriptRoot '..')
        $script:ScriptPath = Join-Path $script:RepoRoot 'scripts/SPSDBMove.ps1'
        $script:Analyzer   = Get-Module -ListAvailable -Name PSScriptAnalyzer |
                              Select-Object -First 1
    }

    It 'PSScriptAnalyzer module is available' {
        $script:Analyzer | Should -Not -BeNullOrEmpty `
            -Because 'CI installs PSScriptAnalyzer; install it locally with Install-Module PSScriptAnalyzer'
    }

    It 'has no Error or Warning findings' -Skip:(-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $findings = Invoke-ScriptAnalyzer -Path $script:ScriptPath -Severity Error, Warning
        if ($findings) {
            $findings | Format-Table RuleName, Severity, Line, Message -AutoSize | Out-String | Write-Host
        }
        $findings | Should -BeNullOrEmpty
    }
}

Describe 'Repository structure' {

    BeforeAll {
        $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    }

    It 'has a top-level README.md' {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'README.md') | Should -BeTrue
    }

    It 'has a top-level LICENSE' {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'LICENSE') | Should -BeTrue
    }

    It 'has a top-level CHANGELOG.md' {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'CHANGELOG.md') | Should -BeTrue
    }

    It 'has a top-level RELEASE-NOTES.md' {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'RELEASE-NOTES.md') | Should -BeTrue
    }

    It 'has a top-level CODE_OF_CONDUCT.md' {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'CODE_OF_CONDUCT.md') | Should -BeTrue
    }

    It 'has wiki pages Home, Getting-Started, Configuration, Usage' {
        foreach ($page in 'Home', 'Getting-Started', 'Configuration', 'Usage') {
            Test-Path -LiteralPath (Join-Path $script:RepoRoot "wiki/$page.md") |
                Should -BeTrue -Because "wiki/$page.md is referenced from README.md"
        }
    }
}
