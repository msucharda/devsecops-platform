BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeadlineHttp.psm1') -Force

    function Open-OneShotServer {
        <#
        .SYNOPSIS
        Serves exactly one HTTP connection on a loopback port in a thread job.
        .PARAMETER Mode
        Complete answers with a full body, Redirect answers 302, Trickle sends one body byte every 200 ms for 20 s.
        #>
        param([ValidateSet('Complete', 'Redirect', 'Trickle')][string] $Mode)
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $selectedMode = $Mode
        $job = Start-ThreadJob -ScriptBlock {
            $server = $using:listener
            $mode = $using:selectedMode
            $client = $server.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 5000
                $reader = [System.IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
                $request = [System.Collections.Generic.List[string]]::new()
                while ($line = $reader.ReadLine()) { $request.Add($line) }
                function Write-Ascii {
                    param($Target, [string] $Text)
                    $bytes = [Text.Encoding]::ASCII.GetBytes($Text)
                    $Target.Write($bytes, 0, $bytes.Length)
                    $Target.Flush()
                }
                switch ($mode) {
                    'Complete' { Write-Ascii $stream "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: 11`r`nConnection: close`r`n`r`n{`"ok`":true}" }
                    'Redirect' { Write-Ascii $stream "HTTP/1.1 302 Found`r`nLocation: http://127.0.0.1:1/other`r`nContent-Length: 0`r`nConnection: close`r`n`r`n" }
                    'Trickle' {
                        Write-Ascii $stream "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: 100000`r`nConnection: close`r`n`r`n"
                        for ($index = 0; $index -lt 100; $index++) {
                            try { Write-Ascii $stream ' ' } catch { break }
                            Start-Sleep -Milliseconds 200
                        }
                    }
                }
                , $request.ToArray()
            }
            finally {
                $client.Close()
                $server.Stop()
            }
        }
        [pscustomobject]@{ Job = $job; Listener = $listener; Uri = "http://127.0.0.1:$($listener.LocalEndpoint.Port)/repos/demo/x/pulls/1" }
    }

    function Close-OneShotServer {
        param($Server)
        $Server.Listener.Stop()
        $null = Wait-Job -Job $Server.Job -Timeout 25
        $output = Receive-Job -Job $Server.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $Server.Job -Force
        return $output
    }
}

Describe 'Invoke-DeadlineHttpGet' {
    It 'returns the status and the complete body and sends the headers' {
        $server = Open-OneShotServer -Mode Complete
        try {
            $response = Invoke-DeadlineHttpGet -Uri $server.Uri -Headers @{ 'X-GitHub-Api-Version' = '2026-03-10' } -Deadline ([DateTime]::UtcNow.AddSeconds(10))
        }
        finally { $request = Close-OneShotServer -Server $server }

        $response.StatusCode | Should -Be 200
        $response.Content | Should -BeExactly '{"ok":true}'
        $request | Should -Contain 'X-GitHub-Api-Version: 2026-03-10'
        $request[0] | Should -BeExactly 'GET /repos/demo/x/pulls/1 HTTP/1.1'
    }

    It 'does not follow a redirect' {
        $server = Open-OneShotServer -Mode Redirect
        try { $response = Invoke-DeadlineHttpGet -Uri $server.Uri -Headers @{} -Deadline ([DateTime]::UtcNow.AddSeconds(10)) }
        finally { $null = Close-OneShotServer -Server $server }

        $response.StatusCode | Should -Be 302
    }

    It 'returns $null at the deadline while the body is still streaming' {
        $server = Open-OneShotServer -Mode Trickle
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try { $response = Invoke-DeadlineHttpGet -Uri $server.Uri -Headers @{} -Deadline ([DateTime]::UtcNow.AddSeconds(2)) }
        finally {
            $watch.Stop()
            $null = Close-OneShotServer -Server $server
        }

        $response | Should -BeNullOrEmpty
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 4
    }

    It 'returns $null without a request when the deadline has passed' {
        Invoke-DeadlineHttpGet -Uri 'http://127.0.0.1:1/' -Headers @{} -Deadline ([DateTime]::UtcNow.AddSeconds(-1)) | Should -BeNullOrEmpty
    }

    It 'throws on a transport error before the deadline' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        $listener.Stop()

        { Invoke-DeadlineHttpGet -Uri "http://127.0.0.1:$port/" -Headers @{} -Deadline ([DateTime]::UtcNow.AddSeconds(10)) } | Should -Throw
    }
}
