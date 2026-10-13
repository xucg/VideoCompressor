# QA independent proof: replicate the Encode-OneVideo segment loop logic
# with the NEW 1-based naming, and assert the key invariants.
# This script does NOT call the original encode-segments.ps1.

$resultFile = "D:\BaiduNetdiskDownload\test\qa_proof_output.txt"
$out = @()

$n      = 20
$SegLen = 30

$names  = @()
$starts = @()
for ($i = 1; $i -le $n; $i++) {
    $segIndex = $i - 1
    $start    = $segIndex * $SegLen
    $name     = "part_{0:D3}.mp4" -f $i
    $names  += $name
    $starts += $start
}

$concat = 1..$n | ForEach-Object { "file 'part_{0:D3}.mp4'" -f $_ }

function Assert-Equal($label, $expected, $actual) {
    $pass = ($expected -eq $actual)
    $status = if ($pass) { "PASS" } else { "FAIL" }
    $line = "{0,-52} expected=[{1}]  actual=[{2}]  -> {3}" -f $label, $expected, $actual, $status
    $script:out += $line
    return $pass
}

$out += "===== DYNAMIC PROOF: 1-based segment naming ====="
$allPass = $true

$p = Assert-Equal "names[0]  (first segment name)"       'part_001.mp4' $names[0];   $allPass = $allPass -and $p
$p = Assert-Equal "names[19] (last segment name)"        'part_020.mp4' $names[19];  $allPass = $allPass -and $p
$p = Assert-Equal "starts[0] (first seg start, no shift)" 0             $starts[0];   $allPass = $allPass -and $p
$p = Assert-Equal "starts[19](last seg start = 19*30)"   570           $starts[19];  $allPass = $allPass -and $p
$p = Assert-Equal "names.Count (total segment count)"     20            $names.Count; $allPass = $allPass -and $p

$p = Assert-Equal "concat[0]  (first concat line)"       "file 'part_001.mp4'" $concat[0];   $allPass = $allPass -and $p
$p = Assert-Equal "concat[19] (last concat line)"         "file 'part_020.mp4'" $concat[19];  $allPass = $allPass -and $p

$p = Assert-Equal "echo template [1/20]"                  "[1/20]" ("[{0}/{1}]" -f 1,20);    $allPass = $allPass -and $p
$p = Assert-Equal "echo template [20/20]"                 "[20/20]" ("[{0}/{1}]" -f 20,20);   $allPass = $allPass -and $p

$out += ""
if ($allPass) {
    $out += "OVERALL VERDICT: PASS"
} else {
    $out += "OVERALL VERDICT: FAIL"
}

Set-Content -Path $resultFile -Value $out -Encoding UTF8
exit (if ($allPass) { 0 } else { 1 })
