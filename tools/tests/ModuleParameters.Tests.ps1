BeforeAll {
    $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $repo 'tools/PlatformTools.psm1') -Force
    $modulePath = Join-Path $repo 'modules'
    $modules = Get-PlatformModuleGraph -ModulesPath $modulePath
    $example = Get-Content (Join-Path $repo 'templates/instance/instance.yaml') -Raw

    function Get-ValidModuleParameter {
        param([string] $Name)
        switch ($Name) {
            'emu-identity' { @{} }
            'organizations' { @{ admin_logins = @('msucharda', 'alice_demo'); billing_email = 'billing@example.test' } }
            'actions-catalog' { @{ target_organizations = @('demo-actions'); security_team = 'actions--security'; vendoring_catalog_path = $null } }
            'organization-roles' { @{ target_organizations = @('demo-platform', 'demo-actions', 'demo-workloads'); security_team = 'Security-Team' } }
            'organization-rulesets' { @{ target_organizations = @('demo-platform', 'demo-actions', 'demo-workloads') } }
            'enterprise-baseline' {
                @{
                    target_organizations = @('demo-platform', 'demo-actions', 'demo-workloads')
                    secret_scanning_bypass_reviewers = @{
                        'demo-platform' = @(@{ reviewer_type = 'TEAM'; reviewer_id = 42 })
                        'demo-actions' = @(@{ reviewer_type = 'TEAM'; reviewer_id = 43 })
                        'demo-workloads' = @(@{ reviewer_type = 'ROLE'; reviewer_id = 44 })
                    }
                }
            }
            default { throw "No documented parameter example for '$Name'." }
        }
    }

    function Test-ModuleParameter {
        param([string] $Name, [System.Collections.IDictionary] $Parameters)
        $instance = ConvertFrom-Yaml $example
        $instance.modules = @{ $Name = @{ parameters = $Parameters } }
        do {
            $count = $instance.modules.Count
            $dependencies = Get-PlatformModuleSelection -Instance $instance -Modules $modules
            foreach ($dependency in $dependencies) {
                if (-not $instance.modules.Contains($dependency)) {
                    $instance.modules[$dependency] = @{ parameters = Get-ValidModuleParameter $dependency }
                }
            }
        } while ($instance.modules.Count -ne $count)
        Get-PlatformInstance -Yaml (ConvertTo-Yaml $instance) -Modules $modules -AllowUnboundApps
    }

    function Get-TerraformVariableDeclaration {
        param([string] $Source)
        $declarations = @([regex]::Matches($Source, '(?ms)^variable\s+"(?<name>[^"]+)"\s*\{(?<body>.*?)^\}'))
        if ($declarations.Count -ne [regex]::Matches($Source, '(?m)^\s*variable\s+"[^"]+"\s*\{').Count) {
            throw 'Unparsed Terraform variable declaration: use the supported multiline variable block format.'
        }
        return ,$declarations
    }

    function Get-SchemaTerraformType {
        param([System.Collections.IDictionary] $Schema)
        $types = @($Schema['type'] | Where-Object { $_ -cne 'null' })
        if ($types.Count -ne 1) { throw 'Expected one non-null Terraform type.' }
        switch ($types[0]) {
            'string' { 'string' }
            'number' { 'number' }
            'boolean' { 'bool' }
            'array' { "list($(Get-SchemaTerraformType $Schema['items']))" }
            'object' {
                if ($Schema.Contains('properties')) {
                    $attributes = foreach ($key in $Schema['properties'].PSBase.Keys) {
                        if ($key -cnotin $Schema['required']) { throw "Object attribute '$key' needs an explicit optional type mapping." }
                        "$key=$(Get-SchemaTerraformType $Schema['properties'][$key])"
                    }
                    "object({$($attributes -join '')})"
                }
                else { "map($(Get-SchemaTerraformType $Schema['additionalProperties']))" }
            }
            default { throw "Unsupported schema type '$($types[0])' in the Terraform contract test." }
        }
    }
}

Describe 'Offline module parameter validation' {
    It 'rejects an undeclared parameter before planning a module' {
        $instance = ConvertFrom-Yaml $example
        $instance.modules = @{ 'emu-identity' = @{ parameters = @{ unexpected = 'value' } } }

        { Get-PlatformInstance -Yaml (ConvertTo-Yaml $instance) -Modules $modules -AllowUnboundApps } |
            Should -Throw '*$.modules.emu-identity.parameters*unexpected*'
    }

    It 'accepts documented parameters and omitted defaults for <Name>' -ForEach @(
        @{ Name = 'emu-identity' }
        @{ Name = 'organizations' }
        @{ Name = 'actions-catalog' }
        @{ Name = 'organization-roles' }
        @{ Name = 'organization-rulesets' }
        @{ Name = 'enterprise-baseline' }
    ) {
        $parameters = Get-ValidModuleParameter $Name
        $validated = Test-ModuleParameter $Name $parameters
        ConvertTo-PlatformCanonicalJson $validated.modules[$Name].parameters |
            Should -BeExactly (ConvertTo-PlatformCanonicalJson $parameters)
    }

    It 'rejects unknown and case-mismatched names for every module' {
        foreach ($name in $modules.PSBase.Keys) {
            foreach ($unknown in @('unexpected', 'TARGET_ORGANIZATIONS')) {
                $parameters = Get-ValidModuleParameter $name
                $parameters[$unknown] = 'value'
                { Test-ModuleParameter $name $parameters } | Should -Throw "*$.modules.$name.parameters*$unknown*"
            }
        }
    }

    It 'rejects each missing required parameter and the missing parameters mapping' {
        foreach ($name in $modules.PSBase.Keys) {
            $required = @($modules[$name].parameterSchema['required'])
            if (-not $required.Count) { continue }
            foreach ($parameter in $required) {
                $parameters = Get-ValidModuleParameter $name
                $parameters.Remove($parameter)
                { Test-ModuleParameter $name $parameters } | Should -Throw "*$parameter*$.modules.$name.parameters*"
            }
            $instance = ConvertFrom-Yaml $example
            $instance.modules = @{ $name = @{} }
            { Get-PlatformInstance -Yaml (ConvertTo-Yaml $instance) -Modules $modules -AllowUnboundApps } |
                Should -Throw "*parameters*$.modules.$name*"
        }
    }

    It 'rejects the wrong container and scalar types of every declared parameter' {
        foreach ($name in $modules.PSBase.Keys) {
            foreach ($parameter in $modules[$name].parameterSchema.properties.PSBase.Keys) {
                $parameters = Get-ValidModuleParameter $name
                $parameters[$parameter] = 17
                { Test-ModuleParameter $name $parameters } | Should -Throw "*$.modules.$name.parameters.$parameter*"
            }
        }
    }

    It 'rejects nested type errors at their configuration paths: <Case>' -ForEach @(
        @{ Case = 'non-string list item'; Name = 'organization-rulesets'; Parameter = 'target_organizations'; Value = @(42); Location = 'target_organizations.0' }
        @{ Case = 'reviewer list instead of organization map'; Name = 'enterprise-baseline'; Parameter = 'secret_scanning_bypass_reviewers'; Value = @(@{ reviewer_type = 'TEAM'; reviewer_id = 42 }); Location = 'secret_scanning_bypass_reviewers' }
        @{ Case = 'reviewer ID string'; Name = 'enterprise-baseline'; Parameter = 'secret_scanning_bypass_reviewers'; Value = @{ 'demo-platform' = @(@{ reviewer_type = 'TEAM'; reviewer_id = '42' }) }; Location = 'secret_scanning_bypass_reviewers.demo-platform.0.reviewer_id' }
        @{ Case = 'reviewer type number'; Name = 'enterprise-baseline'; Parameter = 'secret_scanning_bypass_reviewers'; Value = @{ 'demo-platform' = @(@{ reviewer_type = 42; reviewer_id = 42 }) }; Location = 'secret_scanning_bypass_reviewers.demo-platform.0.reviewer_type' }
        @{ Case = 'missing reviewer field'; Name = 'enterprise-baseline'; Parameter = 'secret_scanning_bypass_reviewers'; Value = @{ 'demo-platform' = @(@{ reviewer_type = 'TEAM' }) }; Location = 'secret_scanning_bypass_reviewers.demo-platform.0' }
    ) {
        $parameters = Get-ValidModuleParameter $Name
        $parameters[$Parameter] = $Value
        { Test-ModuleParameter $Name $parameters } | Should -Throw "*$.modules.$Name.parameters.$Location*"
    }

    It 'does not require parameters for modules without configurable inputs' {
        $instance = ConvertFrom-Yaml $example
        $instance.modules = @{ 'emu-identity' = @{} }
        { Get-PlatformInstance -Yaml (ConvertTo-Yaml $instance) -Modules $modules -AllowUnboundApps } | Should -Not -Throw
    }

    It 'preserves the empty instance template' {
        { Get-PlatformInstance -Yaml $example -Modules $modules } | Should -Not -Throw
    }

    It 'rejects a selected prerequisite whose required module parameters are absent' {
        $instance = ConvertFrom-Yaml $example
        $instance.modules = @{ 'organization-roles' = @{ parameters = Get-ValidModuleParameter 'organization-roles' } }
        { Get-PlatformInstance -Yaml (ConvertTo-Yaml $instance) -Modules $modules -AllowUnboundApps } |
            Should -Throw '*$.modules.organizations*required*'
    }
}

Describe 'Module parameter schema and Terraform contract' {
    It 'selects the schema contract for a schema or Terraform input change' {
        Import-Module (Join-Path $repo 'tools/LocalCi.psm1') -Force
        $files = @(
            (@('modules', 'emu-identity', 'parameters.schema.json') -join '/')
            (@('modules', 'organization-rulesets', 'rulesets', 'variables.tf') -join '/')
        )
        foreach ($file in $files) {
            $selection = Get-LocalCiSelection -RepoPath $repo -ChangedFile @($file) -TerraformRoot @()
            $selection.PesterPath | Should -Contain 'tools/tests/ModuleParameters.Tests.ps1'
        }
    }

    It 'declares exactly the public variables, requiredness and recursive types of every Terraform root' {
        foreach ($name in $modules.PSBase.Keys) {
            $manifest = $modules[$name]
            $schema = $manifest.parameterSchema
            foreach ($file in Get-ChildItem (Join-Path $modulePath $name) -Filter variables.tf -Recurse) {
                $source = Get-Content $file.FullName -Raw
                $variables = Get-TerraformVariableDeclaration -Source $source
                $variables.Count | Should -BeGreaterThan 0 -Because $file.FullName
                $injected = @('instance', 'prerequisites')
                if ($name -ceq 'organization-rulesets' -and $file.Directory.Name -ceq 'rulesets') {
                    $injected += 'ruleset_destroy_started'
                }
                $public = @($variables | Where-Object { $_.Groups['name'].Value -cnotin $injected })
                @($schema.properties.PSBase.Keys | Sort-Object) -join ',' |
                    Should -BeExactly (@($public | ForEach-Object { $_.Groups['name'].Value } | Sort-Object) -join ',') -Because $file.FullName
                $required = @($public | Where-Object { $_.Groups['body'].Value -cnotmatch '(?m)^  default\s*=' } |
                    ForEach-Object { $_.Groups['name'].Value } | Sort-Object)
                @($schema['required'] | Sort-Object) -join ',' | Should -BeExactly ($required -join ',') -Because $file.FullName
                foreach ($variable in $public) {
                    $parameter = $variable.Groups['name'].Value
                    $type = [regex]::Match($variable.Groups['body'].Value,
                        '(?ms)^  type\s*=\s*(?<type>.+?)(?=^  [A-Za-z_]+\s*=|^  validation\s*\{|\z)')
                    $type.Success | Should -BeTrue -Because "$($file.FullName): $parameter"
                    $parameterSchema = $schema.properties[$parameter]
                    if ($manifest.Contains('organizationParameters') -and $parameter -cin $manifest.organizationParameters) {
                        $parameterSchema.type | Should -BeExactly 'object'
                        $parameterSchema = $parameterSchema.additionalProperties
                    }
                    (Get-SchemaTerraformType $parameterSchema) -replace '\s', '' |
                        Should -BeExactly ($type.Groups['type'].Value -replace '\s', '') -Because "$($file.FullName): $parameter"
                }

            }

        }
    }
}

Describe 'Terraform declaration parsing' {
    It 'does not silently skip an inline Terraform input declaration' {
        $source = @(
            'variable "instance" {'
            '  type = any'
            '}'
            'variable "undeclared_input" { type = string }'
        ) -join "`n"
        { Get-TerraformVariableDeclaration -Source $source } | Should -Throw '*Unparsed Terraform variable declaration*'
    }
}

Describe 'Offline module schema loading' {
    BeforeEach {
        $localModules = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item (Join-Path $PSScriptRoot 'fixtures/modules') $localModules -Recurse
        $schemaPath = Join-Path $localModules 'observer/parameters.schema.json'
        $emptySchema = @{ type = 'object'; additionalProperties = $false; properties = @{} }
    }

    It 'rejects a missing schema on a Terraform module' {
        'variable "input" { type = string }' | Set-Content (Join-Path $localModules 'observer/variables.tf')
        { Get-PlatformModuleGraph -ModulesPath $localModules } | Should -Throw '*observer*missing parameter schema*'
    }

    It 'rejects external or rebased references anywhere in the schema: <Keyword>' -ForEach @(
        @{ Keyword = '$ref' }
        @{ Keyword = '$id' }
        @{ Keyword = '$anchor' }
        @{ Keyword = '$dynamicRef' }
        @{ Keyword = '$recursiveRef' }
    ) {
        $emptySchema.properties['options'] = @{ type = 'array'; items = @{ $Keyword = 'https://untrusted.invalid/schema.json' } }
        $emptySchema | ConvertTo-Json -Depth 20 | Set-Content $schemaPath
        { Get-PlatformModuleGraph -ModulesPath $localModules } | Should -Throw "*Unsupported schema keyword '$Keyword'*parameters.schema.json*"
    }

    It 'rejects malformed schemas rather than skipping parameter validation: <Case>' -ForEach @(
        @{ Case = 'invalid JSON'; Json = '{'; Error = '*Invalid module parameter schema*parameters.schema.json*' }
        @{ Case = 'null'; Json = 'null'; Error = '*must be an object*' }
        @{ Case = 'boolean schema'; Json = 'true'; Error = '*must be an object*' }
        @{ Case = 'array'; Json = '[]'; Error = '*must be an object*' }
        @{ Case = 'singleton array'; Json = '[{"type":"object","properties":{},"additionalProperties":false}]'; Error = '*must be an object*' }
        @{ Case = 'missing object contract'; Json = '{}'; Error = '*must declare an object*' }
        @{ Case = 'open properties'; Json = '{"type":"object","properties":{},"additionalProperties":true}'; Error = '*additionalProperties: false*' }
        @{ Case = 'string false'; Json = '{"type":"object","properties":{},"additionalProperties":"false"}'; Error = '*additionalProperties: false*' }
    ) {
        Set-Content $schemaPath $Json
        { Get-PlatformModuleGraph -ModulesPath $localModules } | Should -Throw $Error
    }
}

Describe 'Parameter schema upgrades and protected credential comparison' {
    It 'validates the trusted instance with its own release module schema' {
        $directory = Join-Path $TestDrive 'schema-upgrade'
        $null = New-Item -ItemType Directory -Path $directory
        $trustedModules = Join-Path $directory 'trusted-modules'
        $candidateModules = Join-Path $directory 'candidate-modules'
        Copy-Item (Join-Path $PSScriptRoot 'fixtures/modules') $trustedModules -Recurse
        Copy-Item (Join-Path $PSScriptRoot 'fixtures/modules') $candidateModules -Recurse
        @{
            type = 'object'; additionalProperties = $false
            required = @('old_message'); properties = @{ old_message = @{ type = 'string' } }
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $trustedModules 'observer/parameters.schema.json')
        @{
            type = 'object'; additionalProperties = $false
            required = @('message'); properties = @{ message = @{ type = 'string' } }
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $candidateModules 'observer/parameters.schema.json')
        $instance = ConvertFrom-Yaml $example
        $instance.modules = @{ observer = @{ parameters = @{ old_message = 'old release' } } }
        $trustedPath = Join-Path $directory 'trusted.yaml'
        ConvertTo-Yaml $instance | Set-Content $trustedPath
        $instance.modules.observer.parameters = @{ message = 'new release' }
        $candidatePath = Join-Path $directory 'candidate.yaml'
        ConvertTo-Yaml $instance | Set-Content $candidatePath

        $selected = & (Join-Path $repo 'tools/Select-InstanceModules.ps1') -InstancePath $candidatePath `
            -ModulesPath $candidateModules -TrustedInstancePath $trustedPath -TrustedModulesPath $trustedModules
        $selected | Should -BeExactly '["observer"]'
        $trustedConfig = ConvertFrom-Yaml (Get-Content $trustedPath -Raw)
        $trustedConfig.modules.observer.parameters.old_message = 42
        ConvertTo-Yaml $trustedConfig | Set-Content $trustedPath
        { & (Join-Path $repo 'tools/Select-InstanceModules.ps1') -InstancePath $candidatePath `
                -ModulesPath $candidateModules -TrustedInstancePath $trustedPath -TrustedModulesPath $trustedModules } |
            Should -Throw '*$.modules.observer.parameters.old_message*'
    }
}
