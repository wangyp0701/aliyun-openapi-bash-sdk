#!/bin/bash

for _command in openssl curl; do
    if ! command -v $_command &> /dev/null; then
        echo "Aliyun OpenAPI SDK: $_command command not found"
        exit 127
    fi
done
unset _command

# aliapi_rpc <http_method> <host> <api_version> <api_action> [<--key> <value>...]
aliapi_rpc() {
    if [[ ! -v AliAccessKeyId || ! -v AliAccessKeySecret ]]; then
        echo "Aliyun OpenAPI SDK: 'AliAccessKeyId' or 'AliAccessKeySecret' environment variable not found" >&2
        return 3
    fi

    if [[ $# -lt 4 ]];then
        echo "Aliyun OpenAPI SDK: aliapi_rpc() not enough parameters" >&2
        return 2
    fi

    local _AliAccessKeyId=$AliAccessKeyId _AliAccessKeySecret=$AliAccessKeySecret

    local _http_method=$1
    # 兼容 BusyBox
    # shellcheck disable=SC2018,SC2019
    _http_method=$(tr "a-z" "A-Z" <<< "$_http_method")
    shift
    local _http_host=$1
    shift
    local _api_version=$1
    shift
    local _api_action=$1
    shift

    local -A _api_params
    _api_params=(
        ["AccessKeyId"]=$_AliAccessKeyId
        ["Action"]=$_api_action
        ["Format"]="JSON"
        ["SignatureMethod"]="HMAC-SHA1"
        ["SignatureVersion"]="1.0"
        ["SignatureNonce"]=$(_aliapi_signature_nonce)
        ["Timestamp"]=$(_aliapi_timestamp_rpc)
        ["Version"]=$_api_version
    )
    # 解析其余参数
    while [[ $# -ne 0 ]]
    do
        case $1 in
            --*)
                if [[ $# -le 1 ]]; then
                    echo "Aliyun OpenAPI SDK: aliapi_rpc() '$1' has no value" >&2
                    return 2
                fi
                _api_params[${1:2}]="$2"
                shift
                shift
                ;;
            *)
                echo "Aliyun OpenAPI SDK: aliapi_rpc() Unknown parameter: $1" >&2
                return 2
                ;;
        esac
    done

    local _query_str=""
    local _key _value
    for _key in "${!_api_params[@]}"; do
        _value=${_api_params[$_key]}
        # 参数值如果是以 () 结束，代表需要执行函数获取值，如果函数不存在，使用原始值。
        [[ ($(grep -E "^.+\(\)$" <<< "$_value")  == "$_value" && $(type -t "${_value:0:-2}") == "function") ]] && _value=$(${_value:0:-2})
        _value=$(_aliapi_urlencode "$_value")
        _query_str+="$_key=$_value&"
    done

    local _signature
    _signature=$(_aliapi_signature_rpc "$_http_method" "$_query_str")
    _query_str+="Signature=$(_aliapi_urlencode "$_signature")"
    local _curl_out _http_code _http_url="https://$_http_host/?$_query_str"
    _curl_out=$(mktemp)
    _http_code=$(curl --location --silent --show-error --request "$_http_method" --output "$_curl_out" --write-out "%{http_code}" --connect-timeout 3 "$_http_url") && cat "$_curl_out" - <<< ""
    rm -f "$_curl_out"
    [[ $_http_code -eq 200 ]] && return 0 || return 1
}

_aliapi_signature_rpc() {
    local _http_method=$1 _str _query_str _sign_str
    _str=$(LC_ALL=C echo -n "$2" | tr "&" "\n" | sort)
    _query_str=$(echo -n "$_str" | tr "\n" "&")
    _sign_str="$_http_method&$(_aliapi_urlencode "/")&$(_aliapi_urlencode "$_query_str")"
    echo -n "$_sign_str" | openssl sha1 -hmac "$_AliAccessKeySecret&" -binary | openssl base64 -e
}

_aliapi_timestamp_rpc() {
    # ISO8601 UTC
    date -u -Iseconds
}

_aliapi_signature_nonce() {
}

_aliapi_urlencode() {
    local result
    result=$(curl --get --silent --output /dev/null --write-out "%{url_effective}" --data-urlencode "=$1" "")
    result="${result//+/%20}" # 替换 + 为 %20
    echo "${result#*\?}"
}

if [[ ${#BASH_SOURCE[@]} -eq 1 ]]; then
    set -euf -o pipefail
    if [[ $# -eq 0 ]]; then
        echo "$0 <http_method> <host> <api_version> <api_action> [<--key> <value>...]" >&2
        exit 2
    fi
    aliapi_rpc "$@"
fi
