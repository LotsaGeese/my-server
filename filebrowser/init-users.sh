bash#!/bin/bash
DB="/database/filebrowser.db"

# Update admin password
filebrowser users update admin --password ${FB_ADMIN_PASSWORD} --database $DB

# Create student if it doesn't exist
filebrowser users ls --database $DB | grep -q "student" || \
filebrowser users add student ${FB_STUDENT_PASSWORD} --database $DB \
  --perm.download \
  --perm.share=false \
  --perm.delete=false \
  --perm.rename=false \
  --perm.modify=false \
  --perm.create=false \
  --perm.execute=false \
  --lockPassword

echo "User setup complete"