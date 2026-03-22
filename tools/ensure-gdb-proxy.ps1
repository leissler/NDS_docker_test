Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Port = if ($env:NDS_GDB_PORT) { [int]$env:NDS_GDB_PORT } else { 3333 }
$Retries = if ($env:NDS_GDB_CONNECT_RETRIES) { [int]$env:NDS_GDB_CONNECT_RETRIES } else { 300 }
$IntervalSeconds = if ($env:NDS_GDB_CONNECT_INTERVAL) { [double]$env:NDS_GDB_CONNECT_INTERVAL } else { 0.1 }

function Test-LocalListener {
  param([int]$TcpPort)
  $client = $null
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect("127.0.0.1", $TcpPort, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(300)) {
      return $false
    }
    $client.EndConnect($iar)
    return $true
  } catch {
    return $false
  } finally {
    if ($client) {
      $client.Dispose()
    }
  }
}

for ($i = 0; $i -lt $Retries; $i++) {
  if (Test-LocalListener -TcpPort $Port) {
    exit 0
  }
  Start-Sleep -Milliseconds ([int]([Math]::Max(10, $IntervalSeconds * 1000.0)))
}

Write-Error ("[nds-debug] No local GDB endpoint on 127.0.0.1:{0}." -f $Port)
Write-Error "[nds-debug] Host melonDS did not open ARM9 GDB stub."
exit 1
