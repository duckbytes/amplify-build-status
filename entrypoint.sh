#!/bin/sh -l


APP_ID=$1
BRANCH_NAME=$2
COMMIT_ID=$3
WAIT=$4
TIMEOUT=$5

if [ -z "$AWS_ACCESS_KEY_ID" ] && [ -z "$AWS_SECRET_ACCESS_KEY" ] ; then
  echo "You must provide the action with both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables to connect to AWS."
  exit 1
fi

if [[ $TIMEOUT -lt 0 ]]; then
    echo "Timeout must not be a negative number. Use 0 for unlimited timeout."
    exit 1
fi

get_status () {
    local result;
    result=$(aws amplify list-jobs --app-id "$1" --branch-name "$2" | jq -r ".jobSummaries[] | select(.commitId == \"$3\") | .status")
    echo "$result"
}

check_status () {
    echo "$1"
    if [[ "$1" == "SUCCEED" ]]; then
        return 0
    elif [[ "$1" == "FAILED" ]]; then
        return 2
    else
        return 1
    fi
}

get_status "$APP_ID" "$BRANCH_NAME" "$COMMIT_ID"

STATUS=$(get_status "$APP_ID" "$BRANCH_NAME" "$COMMIT_ID")
check_status "$STATUS"

result=$?

if [[ $result -eq 0 ]]; then
    echo "Build Succeeded"
    exit 0
elif [[ $result -eq 2 ]]; then
    echo "Build Failed"
    exit 1
fi

echo $?
echo "Build in progress"

seconds=$(( $TIMEOUT * 60 ))
count=0

if [[ "$WAIT" == "false" ]]; then
    exit 1
elif [[ "$WAIT" == "true" ]]; then
    while [[ $result -ne 0 ]]; do
        sleep 30
        STATUS=$(get_status "$APP_ID" "$BRANCH_NAME" "$COMMIT_ID")
        check_status "$STATUS"
        result=$?
        if [[ result -eq q ]]; then
            echo "Build Failed!"
            exit 1
        fi
        count=$(( $count + 30 ))
        if [[ $count -gt $seconds ]] && [[ $TIMEOUT -ne 0 ]] ; then
            echo "Timed out"
            exit 1
        fi
    done
fi
