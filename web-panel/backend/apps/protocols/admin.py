from django.contrib import admin
from .models import Protocol


@admin.register(Protocol)
class ProtocolAdmin(admin.ModelAdmin):
    """Configuración del admin para el modelo Protocol"""
    
    list_display = ('name', 'service_name', 'port', 'status', 'date_installed')
    list_filter = ('status', 'date_installed')
    search_fields = ('name', 'service_name')
    readonly_fields = ('date_installed', 'config_data')
    
    fieldsets = (
        ('Información Básica', {
            'fields': ('name', 'service_name', 'port', 'status')
        }),
        ('Configuración', {
            'fields': ('config_data',),
            'classes': ('collapse',)
        }),
        ('Metadata', {
            'fields': ('date_installed',),
            'classes': ('collapse',)
        }),
    )
