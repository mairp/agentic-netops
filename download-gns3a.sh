#!/bin/bash
# Usage: ./download-gns3a.sh <branch>
#
# Example: "./download-gns3a.sh 202012" will download the latest
# image and create a file named e.g. "SONiC-202012-27914.gns3a"
#
# Based on sonic-buildimage/master/platform/vs/sonic-gns3a.sh

set -euo pipefail

BRANCH="${1:?Specify release}"
FILEURL="$(curl -s https://sonic.software/builds.json | jq -r '.["'"${BRANCH}"'"]["sonic-vs.img.gz"]["url"]')"
BUILD="$(curl -s https://sonic.software/builds.json | jq -r '.["'"${BRANCH}"'"]["sonic-vs.img.gz"]["build"]')"
IMGFILE="sonic-vs-${BRANCH}-${BUILD}.img"

if [[ ! -f "${IMGFILE}" ]]; then
  wget -O "${IMGFILE}.gz" "${FILEURL}"
  echo "Uncompressing ..."
  gunzip "${IMGFILE}.gz"
fi

echo "Calculating checksum ..."

if [ "$(uname)" == "Darwin" ]; then
MD5SUMIMGFILE="$(md5 -q "${IMGFILE}")"
LENIMGFILE="$(stat -f %z "${IMGFILE}")"
else
MD5SUMIMGFILE="$(md5sum "${IMGFILE}" | awk '{print $1}')"
LENIMGFILE="$(stat -c %s "${IMGFILE}")"
fi

GNS3APPNAME="SONiC-${BRANCH}-${BUILD}.gns3a"

echo "
{
    \"name\": \"SONiC\",
    \"category\": \"router\",
    \"description\": \"SONiC Virtual Switch/Router\",
    \"vendor_name\": \"SONiC\",
    \"vendor_url\": \"https://azure.github.io/SONiC/\",
    \"product_name\": \"SONiC\",
    \"product_url\": \"https://azure.github.io/SONiC/\",
    \"registry_version\": 3,
    \"status\": \"experimental\",
    \"maintainer\": \"SONiC\",
    \"maintainer_email\": \"sonicproject@googlegroups.com\",
    \"usage\": \"Supports SONiC release: ${BRANCH}\",
    \"first_port_name\": \"eth0\",
    \"qemu\": {
        \"adapter_type\": \"e1000\",
        \"adapters\": 10,
        \"ram\": 4096,
        \"hda_disk_interface\": \"virtio\",
        \"arch\": \"x86_64\",
        \"console_type\": \"telnet\",
        \"boot_priority\": \"d\",
        \"kvm\": \"require\"
    },
    \"images\": [
        {
            \"filename\": \"${IMGFILE}\",
            \"version\": \"${BRANCH}-${BUILD}\",
            \"md5sum\": \"${MD5SUMIMGFILE}\",
            \"filesize\": ${LENIMGFILE}
        }
    ],
    \"versions\": [
        {
            \"name\": \"${BRANCH} build ${BUILD}\",
            \"images\": {
                \"hda_disk_image\": \"${IMGFILE}\"
            }
        }
    ]
}

" > ${GNS3APPNAME}
echo "Done, ${GNS3APPNAME} created"
