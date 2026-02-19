#!/bin/sh

# Download ZIM if DOWNLOAD is set
if [ ! -z "$DOWNLOAD" ]; then
    if [ ! -w /data ]; then
        echo "'/data' directory is not writable by '$(id -n -u):$(id -n -g)' ($(id -u):$(id -g))."
        exit 1
    fi
    ZIM=$(basename "$DOWNLOAD")
    wget "$DOWNLOAD" -O "/data/$ZIM"

    if [ "$#" -eq 0 ]; then
        set -- "$@" "/data/$ZIM"
    fi
fi

PORT=${PORT:-7000}

# Execute Kiwix-serve with arguments (wildcards expand properly)
exec /usr/local/bin/kiwix-serve --port="$PORT" "$@"

# If Kiwix fails, show /data contents
if [ $? -ne 0 ]; then
    echo "Here is the content of /data:"
    find /data -type f
fi
