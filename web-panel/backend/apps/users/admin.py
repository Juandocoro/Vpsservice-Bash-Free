from django.contrib import admin

from .models import SSHUser, UserAccessLog


@admin.register(SSHUser)
class SSHUserAdmin(admin.ModelAdmin):
    list_display = (
        'username',
        'is_active',
        'max_connections',
        'expiry_date',
        'created_date',
    )
    list_filter = ('is_active', 'expiry_date', 'created_date')
    search_fields = ('username', 'notes', 'created_by')
    readonly_fields = ('created_date', 'last_updated', 'password_changed_date')


@admin.register(UserAccessLog)
class UserAccessLogAdmin(admin.ModelAdmin):
    list_display = ('user', 'timestamp', 'ip_address', 'success', 'status')
    list_filter = ('success', 'status', 'timestamp')
    search_fields = ('user__username', 'ip_address')
    readonly_fields = ('timestamp',)
