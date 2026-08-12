package de.flowboardx.flowboard_x

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CountdownPictureInPicturePolicyTest {
    @Test
    fun `picture in picture requires Android 8 and the device feature`() {
        assertFalse(
            CountdownPictureInPicturePolicy(
                sdkInt = 25,
                deviceHasFeature = true,
            ).isSupported,
        )
        assertFalse(
            CountdownPictureInPicturePolicy(
                sdkInt = 36,
                deviceHasFeature = false,
            ).isSupported,
        )
        assertTrue(
            CountdownPictureInPicturePolicy(
                sdkInt = 26,
                deviceHasFeature = true,
            ).isSupported,
        )
    }

    @Test
    fun `only an active timer outside picture in picture may enter`() {
        val policy = CountdownPictureInPicturePolicy(
            sdkInt = 30,
            deviceHasFeature = true,
        )

        assertFalse(
            policy.shouldEnterFromUserLeave(
                timerActive = false,
                alreadyInPictureInPicture = false,
            ),
        )
        assertFalse(
            policy.shouldEnterFromUserLeave(
                timerActive = true,
                alreadyInPictureInPicture = true,
            ),
        )
        assertTrue(
            policy.shouldEnterFromUserLeave(
                timerActive = true,
                alreadyInPictureInPicture = false,
            ),
        )
    }

    @Test
    fun `Android 12 and newer use automatic entry`() {
        assertFalse(
            CountdownPictureInPicturePolicy(
                sdkInt = 30,
                deviceHasFeature = true,
            ).usesAutomaticEnter,
        )
        assertTrue(
            CountdownPictureInPicturePolicy(
                sdkInt = 31,
                deviceHasFeature = true,
            ).usesAutomaticEnter,
        )
    }
}
