#!/bin/bash
# Usage: sudo -u <user> bash ./cp_generated_diffs.sh <entity_name>


CURRENT_USER=$(whoami)
echo "User: ${CURRENT_USER} is executing the script..."
if [ "$CURRENT_USER" != "fabi" ]; then
    echo "Error: This script must be run as 'fabi'. Exiting."
    exit 1
fi

# Variables from arguments with defaults for user and group
ENTITY_NAME="$1"

# Check for required parameters
if [ -z "$ENTITY_NAME" ]; then
  echo "Usage: $0 <entity_name>"
  exit 1
fi

echo "Copying src/Entity/Generated/Generated${ENTITY_NAME}.php.diff into src/Entity/Generated/Generated${ENTITY_NAME}.php"
cp src/Entity/Generated/Generated${ENTITY_NAME}.php.diff src/Entity/Generated/Generated${ENTITY_NAME}.php

echo "Copying src/Form/${ENTITY_NAME}Type.php.diff into src/Form/${ENTITY_NAME}Type.php"
cp src/Form/${ENTITY_NAME}Type.php.diff src/Form/${ENTITY_NAME}Type.php

echo "Copying templates/${ENTITY_NAME}/index.html.twigdiff into templates/${ENTITY_NAME}/index.html.twig"
cp templates/${ENTITY_NAME}/index.html.twigdiff templates/${ENTITY_NAME}/index.html.twig

echo "Copying templates/${ENTITY_NAME}/table.html.twigdiff into templates/${ENTITY_NAME}/table.html.twig"
cp templates/${ENTITY_NAME}/table.html.twigdiff templates/${ENTITY_NAME}/table.html.twig


echo "TODO:\nCheck for availability and correctness of types and type hints in Entity (./src/Entity/Generated/Generated${ENTITY_NAME}).\nRun: \"php bin/console doctrine:schema:update --force\""