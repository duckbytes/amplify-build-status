#!/bin/sh -l

APP_ID=$1
BRANCH_NAME=$2
COMMIT_ID=$3
WAIT=$4
TIMEOUT=$5
NO_FAIL=$6
export AWS_DEFAULT_REGION="$AWS_REGION"

if [[ -z "$AWS_ACCESS_KEY_ID" ]]; then
  echo "You must provide the AWS_ACCESS_KEY_ID environment variable."
  exit 1
fi

if [[ -z "$AWS_SECRET_ACCESS_KEY" ]]; then
  echo "You must provide the AWS_SECRET_ACCESS_KEY environment variable."
  exit 1
fi

if [[ -z "$AWS_DEFAULT_REGION" ]] ; then
  echo "You must provide the AWS_REGION environment variable."
  exit 1
fi

if [[ -z "$APP_ID" ]] ; then
  echo "You must provide the app-id."
  exit 1
fi

if [[ -z "$BRANCH_NAME" ]] ; then
  echo "You must provide the branch-name."
  exit 1
fi

if [[ -z "$COMMIT_ID" ]] ; then
  echo "You must provide the commit-id."
  exit 1
fi

if [[ $TIMEOUT -lt 0 ]]; then
    echo "Timeout must not be a negative number. Use 0 for unlimited timeout."
    exit 1
fi

get_status () {
    local status;
    status=$(aws amplify list-jobs --app-id "$APP_ID" --branch-name "$BRANCH_NAME" | jq -r ".jobSummaries[] | select(.commitId == \"$COMMIT_ID\") | .status")
    exit_status=$?
    # it seems like sometimes status ends up with a new line in it?
    # strip it out
    status=$(echo $status | tr '\n' ' ')
    echo "$status"
    return $exit_status
}

no_fail_check () {
    if [[ $NO_FAIL == "true" ]]; then
        exit 0
    else
        exit 1
    fi
}

STATUS=$(get_status "$APP_ID" "$BRANCH_NAME" "$COMMIT_ID")

if [[ $? -ne 0 ]]; then
    echo "Failed to get status of the job."
    exit 1
fi

if [[ $STATUS == "SUCCEED" ]]; then
    echo "Build Succeeded!"
    echo $(write_output)
    exit 0
elif [[ $STATUS == "FAILED" ]]; then
    echo "Build Failed!"
    echo $(write_output)
    no_fail_check
fi

count=0

if [[ -z $STATUS ]]; then
    echo "No job found for commit $COMMIT_ID. Waiting for job to start..."
    while [[ -z $STATUS ]]; do
        if [[ $count -ge 1800 ]]; then
            echo "Timed out waiting for job to start."
            exit 1
        fi
        sleep 30
        STATUS=$(get_status "$APP_ID" "$BRANCH_NAME" "$COMMIT_ID")
        if [[ $? -ne 0 ]]; then
            echo "Failed to get status of the job."
            exit 1
        fi
        count=$((count+30))
        echo "Waiting for job to start..."
    done
    elif [[ $STATUS ]]; then
        echo "Build in progress... Status: $STATUS"
    fi

seconds=$(( $TIMEOUT * 60 ))
count=0

get_backend_env_name () {
    local env_name;
    local env_arn;
    # get backendEnvironmentArn from get branch first
    env_arn=$(aws amplify get-branch --app-id "$APP_ID" --branch-name "$BRANCH_NAME" | jq -r ".branch.backendEnvironmentArn")
    # search the list of backend environments for the environment name
    env_name=$(aws amplify list-backend-environments --app-id "$APP_ID" | jq -r ".backendEnvironments[] | select(.backendEnvironmentArn == \"$env_arn\") | .environmentName")
    exit_status=$?
    env_name=$(echo $env_name | tr '\n' ' ')
    echo "$env_name"
    return $exit_status
}

write_output () {
    echo "status=$STATUS" >> $GITHUB_OUTPUT
    env_name=$(get_backend_env_name)
    echo "Found environment name: $env_name"
    echo "environment_name=$env_name" >> $GITHUB_OUTPUT
}

if [[ "$WAIT" == "false" ]]; then
    echo $(write_output)
    exit 0
elif [[ "$WAIT" == "true" ]]; then
    while [[ $STATUS != "SUCCEED" ]]; do
        if [[ $TIMEOUT -ne 0 ]] && [[ $count -ge $seconds ]]; then
            echo "Timed out."
            exit 1
        fi
        sleep 30
        STATUS=$(get_status "$APP_ID" "$BRANCH_NAME" "$COMMIT_ID")
        if [[ $? -ne 0 ]]; then
            echo "Failed to get status of the job."
            exit 1
        fi
        if [[ $STATUS == "FAILED" ]]; then
            echo "Build Failed!"
            echo $(write_output)
            no_fail_check
        else
            echo "Build in progress... Status: $STATUS"
        fi
        count=$(( $count + 30 ))
    done
    echo "Build Succeeded!"
    echo $(write_output)
fi
