#!/bin/sh -l

APP_ID=$1
BRANCH_NAME=$2
COMMIT_ID=$3
WAIT=$4
TIMEOUT=$5
export AWS_DEFAULT_REGION="$AWS_REGION"

if [[ -z "$AWS_ACCESS_KEY_ID" ]] && [ -z "$AWS_SECRET_ACCESS_KEY" ] ; then
  echo "You must provide the action with both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables to connect to AWS."
  exit 1
fi

if [[ -z "$AWS_DEFAULT_REGION" ]] ; then
  echo "You must provide AWS_DEFAULT_REGION environment variable to connect to AWS."
  exit 1
fi


if [[ $TIMEOUT -lt 0 ]]; then
    echo "Timeout must not be a negative number. Use 0 for unlimited timeout."
    exit 1
fi

get_status () {
    local status;
    status=$(aws amplify list-jobs --app-id "$1" --branch-name "$2" | jq -r ".jobSummaries[] | select(.commitId == \"$3\") | .status")
    exit_status=$?
    echo "$status"
    return $exit_status
}

STATUS=$(get_status "$APP_ID" "$BRANCH_NAME" "$COMMIT_ID")

if [[ $? -ne 0 ]]; then
    echo "Failed to get status of the job."
    exit 1
fi

if [[ $STATUS == "SUCCEED" ]]; then
    echo "Build Succeeded!"
    exit 0
elif [[ $STATUS == "FAILED" ]]; then
    echo "Build Failed!"
    exit 1
fi

if [[ -z $STATUS ]]; then
    echo "No job found for commit $COMMIT_ID yet but continuing in case Amplify is just being slow."
fi

if [[ $STATUS ]]; then
    echo "Build in progress..."
    echo "Status: $STATUS"
fi

seconds=$(( $TIMEOUT * 60 ))
count=30

if [[ "$WAIT" == "false" ]]; then
    exit 1
elif [[ "$WAIT" == "true" ]]; then
    while [[ $STATUS != "SUCCEED" ]]; do
        sleep 30
        STATUS=$(get_status "$APP_ID" "$BRANCH_NAME" "$COMMIT_ID")
        if [[ $? -ne 0 ]]; then
            echo "Failed to get status of the job."
            exit 1
        fi
        if [[ -z $STATUS ]]; then
            echo "Still no job found for commit $COMMIT_ID."
            if [[ $count -ge 1800 ]]; then
                echo "No Amplify job after 30 minutes, giving up."
                exit 1
            fi
        elif [[ $STATUS == "FAILED" ]]; then
            echo "Build Failed!"
            exit 1
        else
            echo "Build in progress... Status: $STATUS"
        fi
        count=$(( $count + 30 ))
        if [[ $count -ge $seconds ]] && [[ $TIMEOUT -ne 0 ]]; then
            echo "Timed out."
            exit 1
        fi
    done
    echo "Build Succeeded!"
fi
