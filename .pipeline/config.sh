# App settings for the iOS Agent Pipeline. Plain KEY="value" lines only: this file is
# read by both bash and Python. Paths are relative to the app folder.
#
# Defaults live in the pipeline's workflow/defaults.sh and stacks/<stack>/defaults.sh.
# To override one for this app only, copy its line here (e.g. REVIEW_MODE="split").
# Write KEY="value" or KEY='value': no spaces around =, no $VARIABLES (they are not expanded).

# The stack this app is built with (`ios-pipeline stacks` lists them). Chosen during /discuss
# with `ios-pipeline stack select <name>`, which also adds the stack's settings below.
STACK=""
