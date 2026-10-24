# Tracked process ownership is compiled only into debug test hosts.
require_debug_test_configuration() {
  local configuration
  while (( $# )); do
    case "$1" in
      -c|--configuration)
        shift
        configuration="${1:-}"
        ;;
      --configuration=*) configuration="${1#*=}" ;;
      -c=*) configuration="${1#*=}" ;;
      -c?*) configuration="${1#-c}" ;;
      *) shift; continue ;;
    esac
    if [[ "$configuration" != debug ]]; then
      echo 'Jarvis supervised tests require debug configuration; release test hosts do not include ownership tracking. Use swift build -c release for release compilation.' >&2
      return 2
    fi
    (( $# )) && shift
  done
}
