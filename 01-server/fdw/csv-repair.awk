# ==============================================================================
# FILE: csv-repair.awk
# ==============================================================================
# ausearch 4.1.2's --format csv is NOT RFC 4180: no field is ever quoted.
# Verified on 26.04:
#   - a comma in a file name adds a column     (/data/com,ma.txt)
#   - a double quote appears bare mid-field    (/data/quo"te.txt)
#   - newlines and non-UTF-8 bytes are escaped (\012, \xff), so rows never
#     split and the output is valid UTF-8
#
# PostgreSQL reads this output with quote E'\x01' (a byte that never occurs),
# which makes bare double quotes harmless. This script handles the commas:
#
#   - drops the header line (and fails if it isn't the expected one, so a
#     format change between audit-userspace releases breaks loudly)
#   - rows with exactly 25 fields pass through untouched
#   - rows with MORE fields have extra commas inside OBJ_PRIME / OBJ2. Fields
#     1-19 and the last 3 are fixed; OBJ_SEC (an inode number or empty) is
#     the first all-digit field after OBJ_PRIME. The repaired object fields
#     are wrapped in \x01 so PostgreSQL keeps their commas.
#     Limit: a name containing ",<digits>," splits in the wrong place, and a
#     comma in HOW (the executable path) isn't repaired.
#   - rows with FEWER fields are padded with empty fields.
# Repaired and padded rows are counted on stderr (the PostgreSQL log).
# ==============================================================================

BEGIN {
  FS = ","; OFS = ","; Q = "\001"; WANT = 25
  HEADER = "NODE,EVENT,DATE,TIME,YEAR,MONTH,DAY,WEEKDAY,HOUR,MILLI," \
           "GMT_OFFSET,SERIAL_NUM,EVENT_KIND,SESSION,SUBJ_PRIME,SUBJ_SEC," \
           "SUBJ_KIND,ACTION,RESULT,OBJ_PRIME,OBJ_SEC,OBJ2,OBJ_KIND,HOW,KEY"
  repaired = 0; padded = 0
}

/^NODE,EVENT,/ {
  if ($0 != HEADER) {
    print "csv-repair: unexpected ausearch CSV header: " $0 > "/dev/stderr"
    exit 2
  }
  next
}

NF == WANT { print; next }

NF < WANT {
  line = $0
  for (i = NF; i < WANT; i++) line = line ","
  print line
  padded++
  next
}

{
  # Fields 20 .. NF-3 hold OBJ_PRIME, OBJ_SEC, OBJ2.
  first = 20; last = NF - 3
  for (j = first + 1; j < last; j++) if ($j ~ /^[0-9]*$/) break
  if (j >= last) j = last + 1          # no inode found: all into OBJ_PRIME

  objp = $first
  for (i = first + 1; i < j && i <= last; i++) objp = objp "," $i
  objsec = (j <= last) ? $j : ""
  obj2 = ""
  for (i = j + 1; i <= last; i++) obj2 = (obj2 == "" ? $i : obj2 "," $i)

  out = $1
  for (i = 2; i <= 19; i++) out = out "," $i
  out = out "," q(objp) "," objsec "," q(obj2)
  out = out "," $(NF - 2) "," $(NF - 1) "," $NF
  print out
  repaired++
}

# Quote a non-empty field with \001; empty stays empty (NULL), as elsewhere.
function q(s) { return s == "" ? "" : Q s Q }

END {
  if (repaired || padded)
    printf "csv-repair: repaired %d rows with unquoted commas, padded %d\n",
           repaired, padded > "/dev/stderr"
}
