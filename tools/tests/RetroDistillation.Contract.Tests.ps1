BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

Describe 'Distillation instruction contract' {
    It 'publishes a Czech distiller profile with an explicit model and a prompt shorter than 30000 characters' {
        $path = Join-Path $root '.github\agents\retro-distiller.agent.md'
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -MatchExactly '(?m)^name: retro-distiller$'
        $text | Should -MatchExactly '(?m)^model: claude-opus-5.5$'
        $text | Should -MatchExactly 'reasoning_effort: xhigh'
        ($text -split '(?m)^---\n', 3)[2].Length | Should -BeLessThan 30000
        $text.Contains("`r") | Should -BeFalse
    }

    It 'links an existing guide procedure from the AGENTS index without pretending it is a distilled rule' {
        $agents = Get-Content (Join-Path $root 'AGENTS.md') -Raw
        $section = [regex]::Match($agents, '(?ms)^### Průvodce agentů\n.*?(?=^### |^## |\z)').Value
        $links = [regex]::Matches($section, '\]\((docs/agents/guide/[a-z0-9-]+\.md)\)')
        $links.Count | Should -BeGreaterThan 0
        foreach ($link in $links) {
            Test-Path (Join-Path $root $link.Groups[1].Value) | Should -BeTrue
        }
        @($links | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique).Count | Should -Be $links.Count
        $guide = Get-Content (Join-Path $root 'docs\agents\guide\distillation.md') -Raw
        $guide | Should -MatchExactly 'syntetick'
        $guide | Should -MatchExactly 'nezávisl'
        $guide | Should -MatchExactly 'neověřen'
    }
}
