#!/bin/sh
#
# See common-aws.sh for inputs
#

set -e

BASE_DIR="`dirname \"$0\"`"

# Run common AWS Cloudformation parts
. "$BASE_DIR/common-aws.sh"

if [ -d "$STACK_OUTPUTS_DIR" ] && [ -z "$SKIP_STACK_OUTPUTS_DIR" -o x"$SKIP_STACK_OUTPUTS_DIR" = "false" ] && [ x"$SKIP_EXISTING" != x"true" ]; then
	 FATAL "Existing stack outputs directory: '$STACK_OUTPUTS_DIR', do you need to run\n\t$BASE_DIR/update_aws_cloudformation.sh instead?"
fi

PREAMBLE_STACK="$DEPLOYMENT_NAME-preamble"
BOSH_SSH_KEY_NAME="$DEPLOYMENT_NAME-key"

# We don't want to store the full path when we add the ssh-key location, so we use a relative one - but we use the absolute one for our checks
BOSH_SSH_KEY_FILENAME="$DEPLOYMENT_DIR/ssh-key"
BOSH_SSH_KEY_FILENAME_RELATIVE="$DEPLOYMENT_DIR_RELATIVE/ssh-key"

# We use older options in find due to possible lack of -printf and/or -regex options
STACK_FILES="`find "$CLOUDFORMATION_DIR" -mindepth 1 -maxdepth 1 -name "$AWS_CONFIG_PREFIX-*.json" | awk -F/ '!/preamble/{print $NF}' | sort`"
STACK_TEMPLATES_FILES="`find "$CLOUDFORMATION_DIR/Templates" -mindepth 1 -maxdepth 1 -name "*.json" | awk -F/ '{printf("%s/%s\n",$(NF-1),$NF)}' | sort`"
[ -d "$LOCAL_CLOUDFORMATION_DIR" ] && STACK_LOCAL_FILES="`find "$LOCAL_CLOUDFORMATION_DIR" -mindepth 1 -maxdepth 1 -name "*.json" | awk -F/ '{printf("%s/%s\n",$(NF-1),$NF)}' | sort`"

cd "$CLOUDFORMATION_DIR"
validate_json_files "$STACK_PREAMBLE_FILENAME" $STACK_FILES $STACK_TEMPLATES_FILES $STACK_LOCAL_FILES
cd - >/dev/null

if [ ! -d "$STACK_OUTPUTS_DIR" ]; then
	INFO "Creating directory to hold stack outputs"
	mkdir -p "$STACK_OUTPUTS_DIR"
fi

if [ ! -d "$STACK_PARAMETERS_DIR" ]; then
	INFO "Creating directory to hold stack parameters"
	mkdir -p "$STACK_PARAMETERS_DIR"
fi

if [ -z "$SKIP_EXISTING" -o x"$SKIP_EXISTING" != x"true" ] || ! stack_exists "$PREAMBLE_STACK"; then
	INFO 'Checking for existing Cloudformation stack'
	"$AWS" --output text --query "StackSummaries[?starts_with(StackName,'$DEPLOYMENT_NAME-') && StackStatus != 'DELETE_COMPLETE'].StackName" \
		cloudformation list-stacks | grep -q "^$DEPLOYMENT_NAME" && FATAL 'Stack(s) exists'

	INFO 'Validating Cloudformation Preamble Template'
	"$AWS" cloudformation validate-template --template-body "$STACK_PREAMBLE_URL"

	# The preamble must be kept smaller than 51200 as we use it to host templates
	INFO 'Creating Cloudformation stack preamble'
	INFO 'Stack details:'
	"$AWS" \
		cloudformation create-stack \
		--capabilities CAPABILITY_IAM \
		--capabilities CAPABILITY_NAMED_IAM \
		--stack-name "$DEPLOYMENT_NAME-preamble" \
		--capabilities CAPABILITY_IAM \
		--capabilities CAPABILITY_NAMED_IAM \
		--template-body "$STACK_PREAMBLE_URL"

	INFO 'Waiting for Cloudformation stack to finish creation'
	"$AWS" cloudformation wait stack-create-complete --stack-name "$DEPLOYMENT_NAME-preamble" || FATAL 'Failed to create Cloudformation preamble stack'
fi

# Always generate outputs
parse_aws_cloudformation_outputs "$DEPLOYMENT_NAME-preamble" >"$STACK_PREAMBLE_OUTPUTS"

[ -f "$STACK_PREAMBLE_OUTPUTS" ] || FATAL "No preamble outputs available: $STACK_PREAMBLE_OUTPUTS"

INFO "Loading: $STACK_PREAMBLE_OUTPUTS"
. "$STACK_PREAMBLE_OUTPUTS"

INFO 'Copying templates to S3'
"$AWS" s3 sync "$CLOUDFORMATION_DIR/" "s3://$templates_bucket_name" --exclude '*' --include "$AWS_CONFIG_PREFIX-*.json" --include 'Templates/*.json'

for stack_file in $STACK_FILES $STACK_LOCAL_FILES; do
	STACK_NAME="`stack_file_name "$DEPLOYMENT_NAME" "$stack_file"`"
	STACK_URL="$templates_bucket_http_url/$stack_file"

	INFO "Validating Cloudformation template: '$stack_file'"
	"$AWS" cloudformation validate-template --template-url "$STACK_URL" || FAILED=$?

	if [ 0$FAILED -ne 0 ] && [ -z "$SKIP_EXISTING" -o x"$SKIP_EXISTING" != x"true" ]; then
		INFO 'Cleaning preamble S3 bucket'
		"$AWS" s3 rm --recursive "s3://$templates_bucket_name"

		INFO "Deleting stack: '$PREAMBLE_STACK'"
		"$AWS" cloudformation delete-stack --stack-name "$PREAMBLE_STACK"

		INFO "Waiting for Cloudformation stack deletion to finish creation: '$PREAMBLE_STACK'"
		"$AWS" cloudformation wait stack-delete-complete --stack-name "$PREAMBLE_STACK" || FATAL 'Failed to delete Cloudformation stack'

		[ -d "$STACK_OUTPUTS_DIR" ] && rm -rf "$STACK_OUTPUTS_DIR"

		FATAL "Problem validating template: '$stack_file'"
	elif [ 0$FAILED -ne 0 ]; then
		FATAL "Failed to validate stack: $STACK_NAME, $stack_file"
	fi
done

for stack_file in $STACK_FILES; do
	STACK_NAME="`stack_file_name "$DEPLOYMENT_NAME" "$stack_file"`"
	STACK_URL="$templates_bucket_http_url/$stack_file"
	STACK_PARAMETERS="$STACK_PARAMETERS_DIR/parameters-$STACK_NAME.$STACK_PARAMETERS_SUFFIX"
	STACK_OUTPUTS="$STACK_OUTPUTS_DIR/outputs-$STACK_NAME.$STACK_OUTPUTS_SUFFIX"

	if [ -n "$SKIP_EXISTING" -a x"$SKIP_EXISTING" = x"true" ] && stack_exists "$STACK_NAME"; then
		WARN "Stack already exists, skipping: $STACK_NAME"

		STACK_EXISTS=1
	fi

	[ -f "$AWS_PASSWORD_CONFIG_FILE" ] || echo '# AWS Passwords' >"$AWS_PASSWORD_CONFIG_FILE"
	for i in `find_aws_parameters "$CLOUDFORMATION_DIR/$stack_file" '^[A-Za-z]+Password$' | capitalise_aws`; do
		# eg rds_cf_instance_password
		lower_varname="`echo $i | tr '[[:upper:]]' '[[:lower:]]'`"

		if grep -Eq "^$lower_varname=" "$AWS_PASSWORD_CONFIG_FILE"; then
			eval `grep -E "^$lower_varname=" "$AWS_PASSWORD_CONFIG_FILE"`

			eval "$i"="\$$lower_varname"

			continue
		fi

		# eg RDS_CF_INSTANCE_PASSWORD
		password="`generate_password 32`"

		eval "$i='$password'"

		echo "$lower_varname='$password'"
	done >>"$AWS_PASSWORD_CONFIG_FILE"

	# Always renegerate the parameters file
	if [ -z "$STACK_EXISTS" -o ! -f "$STACK_PARAMETERS" ]; then
		INFO "Generating Cloudformation parameters JSON file for '$STACK_NAME': $STACK_PARAMETERS"
		generate_parameters_file "$CLOUDFORMATION_DIR/$stack_file" >"$STACK_PARAMETERS"
	fi

	if [ -z "$STACK_EXISTS" ]; then
		INFO "Creating Cloudformation stack: '$STACK_NAME'"
		INFO 'Stack details:'
		"$AWS" cloudformation create-stack \
			--stack-name "$STACK_NAME" \
			--template-url "$STACK_URL" \
			--capabilities CAPABILITY_IAM \
			--capabilities CAPABILITY_NAMED_IAM \
			--on-failure DO_NOTHING \
			--parameters "file://$STACK_PARAMETERS"

		INFO "Waiting for Cloudformation stack to finish creation: '$STACK_NAME'"
		"$AWS" cloudformation wait stack-create-complete --stack-name "$STACK_NAME" || FATAL 'Failed to create Cloudformation stack'
	fi

	# Generate outputs
	if [ x"$UPDATE_OUTPUTS" = x"true" -o -z "$STACK_EXISTS" -o ! -f "$STACK_OUTPUTS" ]; then
		parse_aws_cloudformation_outputs "$STACK_NAME" >"$STACK_OUTPUTS"

		NEW_OUTPUTS=1
	fi

	unset STACK_EXISTS
done

if [ -n "$NEW_OUTPUTS" ]; then
	INFO 'Configuring DNS settings'
	load_output_vars "$STACK_OUTPUTS_DIR" NONE vpc_cidr
	calculate_dns "$vpc_cidr" >"$STACK_OUTPUTS_DIR/outputs-dns.$STACK_OUTPUTS_SUFFIX"
fi

# Check if we have an existing AWS SSH key that has the correct name
"$AWS" ec2 describe-key-pairs --key-names "$BOSH_SSH_KEY_NAME" >/dev/null 2>&1 && AWS_KEY_EXISTS='true'

if [ x"$REGENERATE_SSH_KEY" = x"true" -a -f "$BOSH_SSH_KEY_FILENAME" ]; then
	INFO 'Deleting local SSH key'
	rm -f "$BOSH_SSH_KEY_FILENAME" "$BOSH_SSH_KEY_FILENAME.pub"
fi

# We don't have a local key, so we have to generate one
if [ ! -f "$BOSH_SSH_KEY_FILENAME" ]; then
	INFO 'Generating SSH key'
	[ -n "$SECURE_SSH_KEY" ] && ssh-keygen -f "$BOSH_SSH_KEY_FILENAME" || ssh-keygen -f "$BOSH_SSH_KEY_FILENAME" -P ''

	DELETE_AWS_SSH_KEY='true'
fi

if [ x"$AWS_KEY_EXISTS" = x"true" -a x"$DELETE_AWS_SSH_KEY" != x"true" ]; then
	INFO 'Generating local SSH key fingerprint'
	LOCAL_SSH_FINGERPRINT="`openssl pkey -in "$BOSH_SSH_KEY_FILENAME" -pubout -outform DER | openssl md5 -c | awk '{print $NF}'`"

	INFO 'Obtaining AWS SSH key fingerprint'
	AWS_SSH_FINGERPRINT="`"$AWS" --output text --query "KeyPairs[?KeyName == '$BOSH_SSH_KEY_NAME'].KeyFingerprint" ec2 describe-key-pairs --key-names "$BOSH_SSH_KEY_NAME"`"

	INFO 'Checking if we need to reupload AWS SSH key'
	[ x"$AWS_SSH_FINGERPRINT" != x"$LOCAL_SSH_FINGERPRINT" ] && DELETE_AWS_SSH_KEY='true'
fi

if [ x"$AWS_KEY_EXISTS" = x"true" -a x"$DELETE_AWS_SSH_KEY" = x"true" ]; then
	INFO 'Deleting AWS SSH key'
	"$AWS" ec2 delete-key-pair --key-name "$BOSH_SSH_KEY_NAME"

	AWS_KEY_EXISTS='false'
fi

# Check if we have a valid key
[ -f "$BOSH_SSH_KEY_FILENAME" ] || FATAL "SSH key does not exist '$BOSH_SSH_KEY_FILENAME'"

if [ x"$AWS_KEY_EXISTS" != x"true" ]; then
	INFO "Uploading $BOSH_SSH_KEY_NAME to AWS"
	KEY_DATA="`cat "$BOSH_SSH_KEY_FILENAME.pub"`"
	"$AWS" ec2 import-key-pair --key-name "$BOSH_SSH_KEY_NAME" --public-key-material "$KEY_DATA"
fi

if [ ! -f "$BOSH_SSH_CONFIG" ]; then
	INFO 'Creating additional environment configuration'
	cat >"$BOSH_SSH_CONFIG" <<EOF
# Bosh SSH vars
bosh_ssh_key_name='$BOSH_SSH_KEY_NAME'
bosh_ssh_key_file='$BOSH_SSH_KEY_FILENAME_RELATIVE'
EOF
fi

post_deploy_scripts AWS

INFO 'AWS Deployment Complete'
