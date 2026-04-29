from django.contrib import admin
from .models import Protocol


@admin.register(Protocol)
class ProtocolAdmin(admin.ModelAdmin):
    list_display = (
        'name',
        'port',
        'protocol_type',
        'is_installed',
        'is_active',
        'installed_date',
    )
    list_filter = ('protocol_type', 'is_installed', 'is_active', 'installed_date')
    search_fields = ('name', 'description')
    readonly_fields = ('created_date', 'installed_date', 'last_updated')
