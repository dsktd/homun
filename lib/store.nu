# Write text to a file atomically: a temp file in the same directory, then rename, so a reader
# never sees half a file. `$value | to json | store $file`.
export def main [file: path]: string -> nothing {
    mkdir ($file | path dirname)
    let tmp = $"($file).tmp.(random uuid)"
    $in | save -f $tmp
    mv -f $tmp $file
}
