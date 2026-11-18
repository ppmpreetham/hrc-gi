@tool
extends EditorPlugin
# HRCGlobalIllumination, HRCEmitter, HRCOccluder and HRCDisplay register themselves through
# class_name, so they already show up in the Add Node dialog. Registering them again with
# add_custom_type would list each one twice.
