#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
	cat >&2 <<-USAGE
		Usage: $0 [-?|-h|--help] [<binary_path> <string_path>]

		-? | -h | --help             Prints this message
		-a | --all                   Process all data (overrides max items)
		-b N | --batch-size-items N  Process data in batches of N (defautls to 25)
		-m N | --max-items N         Limits processing to the first N entries (defaults to 100)
		-t NAME | --table NAME       DynamoDB table name (defaults to "project")

		Paths are specified as .x.y.z for { "x": { "y": { "z": data }}}. More
		generally, they must be valid "jq" paths.

		Binary paths must point to a string that contains a base64-encoded,
		gzipped json, so that "base64 --decode | gzip -d" will turn that
		string into valid json.

		String paths must point to a string that contains valid json. For
		example, .x in { "x": "{ \"a\": 5 }" }.

		Use a non-existing path if there's no binary or string path. For
		example, ".no.binary.path .path.to.string" if there's string data
		on the .path.to.string, but not binary data, and ".no.binary.path"
		is not an existing path in the input data.
	USAGE
	exit 1
}

while [[ $# -gt 0 && "$1" == -* ]]; do
	case "$1" in
		-\? | -h | --help) usage ;;
		-a | --all) ALL=1 ;;
		-b | --batch-size) shift; BATCH_SIZE="${1}" ;;
		-m | --max-items) shift; MAX_ITEMS="${1}" ;;
		-t | --table) shift; TABLE="${1}" ;;
	esac
	shift
done

if [[ $# -ne 0 && $# -ne 2 ]]; then
	echo >&2 "Either both paths or no paths must be passed!"
	exit 2
fi

BINARY_PATH="${1:-.projectBinaryData.B}"
STRING_PATH="${2:-.projectData.S}"
BINARY_DEFAULT_QUERY="${BINARY_PATH}"' // "H4sIABWa/lwCA6uu5QIABrCh3QMAAAA="'
STRING_DEFAULT_QUERY="${STRING_PATH}"' // "{}"'
BINARY_JQ_PATH="$(jq -n -c "path($BINARY_PATH)")"
STRING_JQ_PATH="$(jq -n -c "path($STRING_PATH)")"
# shellcheck disable=SC2140
OUTPUT_QUERY=". as \$uncompressed | \$line | setpath(${BINARY_JQ_PATH}; \$uncompressed) | "\
"setpath(${STRING_JQ_PATH}; ${STRING_DEFAULT_QUERY} | fromjson)"

: "${ALL:=}"
: "${MAX_ITEMS:=100}"
: "${TABLE:=projects}"
: "${BATCH_SIZE:=25}"

NEXTTOKEN='null'
j=0
{
	DATA=$(aws dynamodb scan --output json --table-name "$TABLE" --max-items "$BATCH_SIZE")
	jq -r -c '.Items[]' <<< "$DATA"
	NEXTTOKEN=$(jq -r '.NextToken' <<< "$DATA") && j="$BATCH_SIZE"
	echo $j >&2
	while [[ "${NEXTTOKEN}" != 'null' && ( -n "${ALL}" || $j -lt "$MAX_ITEMS" ) ]]; do
		DATA=$(aws dynamodb scan --output json --table-name "$TABLE" --starting-token "$NEXTTOKEN" --max-items "$BATCH_SIZE")
		jq -r -c '.Items[]' <<< "$DATA"
		NEXTTOKEN=$(jq -r '.NextToken' <<< "$DATA")
		j=$((j + BATCH_SIZE))
		echo $j >&2
	done
} | while read -r line; do
    echo "$line" | jq -r -c "${BINARY_DEFAULT_QUERY}" | base64 --decode | gzip -d |
	    jq --argjson line "$line" -r -c "${OUTPUT_QUERY}"
done

# vim: set ts=4 sw=4 tw=100 noet :
